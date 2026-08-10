namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Collections.Generic;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  /// <summary>
  /// Call this to force re-discovery of obstacle shapes (e.g. when obstacles are added/removed at runtime).
  /// </summary>
  public void InvalidateObstacleCache()
  {
    // Disconnect visibility signals before clearing — prevents stale subscriptions
    // accumulating if InvalidateObstacleCache is called multiple times.
    foreach (var node in _visibilityTrackedNodes)
    {
      if (IsInstanceValid(node))
      {
        node.VisibilityChanged -= InvalidateObstacleCache;
      }
    }
    _visibilityTrackedNodes.Clear();

    _staticShapes = null;
    _movableShapes = null;
    _staticObstacleData = null;
    _triggerZones = null;
  }

  /// <summary>
  /// Recursively connects VisibilityChanged on every Node3D under <paramref name="node"/>
  /// so that toggling visibility on any obstacle (or its parent) automatically rebuilds
  /// the obstacle cache next frame.
  /// </summary>
  private void ConnectVisibilitySignals(Node node)
  {
    if (node is Node3D n3d)
    {
      // Trigger zone shapes are CPU-side only and not in the GPU obstacle buffer.
      // Connecting them would cause InvalidateObstacleCache to fire mid-loop when
      // GateTrigger sets _zone.visible = false, nulling _triggerZones during iteration.
      var isTriggerZone =
        node is CollisionShape3D cs
        && (cs.HasMeta("damage") || cs.HasMeta("multiply") || cs.HasMeta("add"));

      if (!isTriggerZone)
      {
        n3d.VisibilityChanged += InvalidateObstacleCache;
        _visibilityTrackedNodes.Add(n3d);
      }
    }
    foreach (var child in node.GetChildren())
    {
      ConnectVisibilitySignals(child);
    }
  }

  private void EnsureObstacleCache()
  {
    if (_staticShapes != null)
    {
      return;
    }

    _staticShapes = [];
    _movableShapes = [];

    if (ObstaclesRoot == null)
    {
      return;
    }

    var staticRoot = ObstaclesRoot.GetNodeOrNull("Static");
    var movableRoot = ObstaclesRoot.GetNodeOrNull("Movable");

    if (staticRoot != null)
    {
      FindCollisionShapes(staticRoot, _staticShapes);
    }

    if (movableRoot != null)
    {
      FindCollisionShapes(movableRoot, _movableShapes);
    }

    // Pre-compute static obstacle data (zero velocity, zero angular_vel).
    // Each shape emits at most one obstacle (OBSTACLE_STRIDE floats), so size
    // for the worst case and trim to what was actually written.
    var staticData = new float[_staticShapes.Count * OBSTACLE_STRIDE];
    var staticOffset = 0;
    foreach (var cs in _staticShapes)
    {
      EmitObstacleData(cs, Vector2.Zero, 0f, staticData, ref staticOffset);
    }

    if (staticOffset < staticData.Length)
    {
      Array.Resize(ref staticData, staticOffset);
    }

    _staticObstacleData = staticData;

    // Scan entire ObstaclesRoot for trigger zones.  These are CollisionShape3D nodes
    // with metadata keys "kill", "multiply", or "add".  They are NOT added to the GPU
    // obstacle buffer (hogs pass through them); detection is CPU-side.
    _triggerZones = [];
    if (ObstaclesRoot != null)
    {
      ScanForTriggers(ObstaclesRoot, _triggerZones);
    }

    // Connect VisibilityChanged on every Node3D under ObstaclesRoot so that toggling
    // any obstacle's (or its parent's) visibility auto-invalidates this cache.
    // Godot propagates NOTIFICATION_VISIBILITY_CHANGED down the tree, so a parent
    // toggle correctly fires signals on all children.
    ConnectVisibilitySignals(ObstaclesRoot);
  }

  private void ExtractObstacles(float delta)
  {
    EnsureObstacleCache();

    // Calculate required capacity
    var maxFloats = _staticObstacleData.Length + (_movableShapes.Count * OBSTACLE_STRIDE);
    EnsureObstacleStagingCapacity(maxFloats);

    // Copy cached static data into staging buffer
    Array.Copy(_staticObstacleData, 0, _obstacleStaging, 0, _staticObstacleData.Length);
    var writeOffset = _staticObstacleData.Length;

    // Compute movable obstacles with velocity tracking.
    // Swap pre-allocated dicts instead of allocating a new one each frame.
    _currentObstacleState.Clear();
    var invDelta = delta > 0.0001f ? 1.0f / delta : 0f;

    foreach (var cs in _movableShapes)
    {
      if (cs.Shape == null || cs.Disabled)
      {
        continue;
      }

      var globalXform = cs.GlobalTransform;
      var center = new Vector2(globalXform.Origin.X, globalXform.Origin.Z);
      var yRot = globalXform.Basis.GetEuler().Y;

      var linearVel = Vector2.Zero;
      var angularVel = 0f;
      if (_prevObstacleState.TryGetValue(cs, out var prev))
      {
        linearVel = (center - prev.center) * invDelta;
        var dAngle = yRot - prev.yRot;
        dAngle = Mathf.Wrap(dAngle + Mathf.Pi, 0, Mathf.Tau) - Mathf.Pi;
        angularVel = dAngle * invDelta;
      }

      _currentObstacleState[cs] = (center, yRot);
      EmitObstacleData(cs, linearVel, angularVel, _obstacleStaging, ref writeOffset);
    }

    (_prevObstacleState, _currentObstacleState) = (_currentObstacleState, _prevObstacleState);
    _numObstacles = writeOffset / OBSTACLE_STRIDE;
  }

  private void EnsureObstacleStagingCapacity(int requiredFloats)
  {
    if (requiredFloats <= _obstacleCapacity)
    {
      return;
    }

    // Grow with headroom to avoid frequent resizing
    _obstacleCapacity = Math.Max(requiredFloats, _obstacleCapacity * 2);
    _obstacleStaging = new float[_obstacleCapacity];
    _obstacleBytes = new byte[_obstacleCapacity * sizeof(float)];
  }

  /// <summary>
  /// Writes obstacle data directly into a pre-allocated float array at the given offset.
  /// Used per-frame for movable obstacles (zero-alloc) and once at cache build for
  /// static obstacles. Emits nothing for disabled/shapeless/unsupported shapes.
  /// </summary>
  private void EmitObstacleData(
    CollisionShape3D cs,
    Vector2 linearVel,
    float angularVel,
    float[] buffer,
    ref int offset
  )
  {
    if (cs.Shape == null || cs.Disabled)
    {
      return;
    }

    var globalXform = cs.GlobalTransform;
    var center = new Vector2(globalXform.Origin.X, globalXform.Origin.Z);
    var yRot = globalXform.Basis.GetEuler().Y;
    var cosY = Mathf.Cos(yRot);
    var sinY = Mathf.Sin(yRot);

    switch (cs.Shape)
    {
      case SphereShape3D sphere:
        WriteObstacle(
          buffer,
          ref offset,
          center.X,
          center.Y,
          sphere.Radius,
          0f,
          1f,
          0f,
          linearVel.X,
          linearVel.Y,
          OBS_TYPE_CIRCLE,
          ObstacleMargin,
          angularVel
        );
        break;
      case CylinderShape3D cylinder:
        WriteObstacle(
          buffer,
          ref offset,
          center.X,
          center.Y,
          cylinder.Radius,
          0f,
          1f,
          0f,
          linearVel.X,
          linearVel.Y,
          OBS_TYPE_CIRCLE,
          ObstacleMargin,
          angularVel
        );
        break;
      case BoxShape3D box:
        WriteObstacle(
          buffer,
          ref offset,
          center.X,
          center.Y,
          box.Size.X * 0.5f,
          box.Size.Z * 0.5f,
          cosY,
          -sinY,
          linearVel.X,
          linearVel.Y,
          OBS_TYPE_OBB,
          ObstacleMargin,
          angularVel
        );
        break;
      case ConvexPolygonShape3D convex:
        var (obbCenter, obbHalf, obbAngle) = ComputeMinObb(convex.Points, globalXform);
        WriteObstacle(
          buffer,
          ref offset,
          obbCenter.X,
          obbCenter.Y,
          obbHalf.X,
          obbHalf.Y,
          Mathf.Cos(obbAngle),
          Mathf.Sin(obbAngle),
          linearVel.X,
          linearVel.Y,
          OBS_TYPE_OBB,
          ObstacleMargin,
          angularVel
        );
        break;
      case ConcavePolygonShape3D concave:
        var faces = concave.GetFaces();
        if (faces.Length >= 3)
        {
          var (cCenter, cHalf, cAngle) = ComputeMinObb(faces, globalXform);
          WriteObstacle(
            buffer,
            ref offset,
            cCenter.X,
            cCenter.Y,
            cHalf.X,
            cHalf.Y,
            Mathf.Cos(cAngle),
            Mathf.Sin(cAngle),
            linearVel.X,
            linearVel.Y,
            OBS_TYPE_OBB,
            ObstacleMargin,
            angularVel
          );
        }

        break;
      default:
        break;
    }
  }

  private static void WriteObstacle(
    float[] buf,
    ref int offset,
    float centerX,
    float centerZ,
    float halfExtX,
    float halfExtZ,
    float localAxisX,
    float localAxisZ,
    float velX,
    float velZ,
    float type,
    float margin,
    float angularVel,
    float pad = 0f
  )
  {
    buf[offset + OBS_CENTER_X] = centerX;
    buf[offset + OBS_CENTER_Z] = centerZ;
    buf[offset + OBS_HALF_EXT_X] = halfExtX;
    buf[offset + OBS_HALF_EXT_Z] = halfExtZ;
    buf[offset + OBS_LOCAL_X_X] = localAxisX;
    buf[offset + OBS_LOCAL_X_Z] = localAxisZ;
    buf[offset + OBS_VEL_X] = velX;
    buf[offset + OBS_VEL_Z] = velZ;
    buf[offset + OBS_TYPE] = type;
    buf[offset + OBS_MARGIN] = margin;
    buf[offset + OBS_ANGULAR_VEL] = angularVel;
    buf[offset + OBS_PAD] = pad;
    offset += OBSTACLE_STRIDE;
  }

  private void UpdateObstacleBuffer(float delta)
  {
    ExtractObstacles(delta);
    if (_numObstacles <= 0)
    {
      return;
    }

    var byteCount = _numObstacles * OBSTACLE_STRIDE * sizeof(float);

    // Growth is queued ahead of the data write, so the write resolves to the new buffer.
    // The obstacle data is rewritten in full every frame, so nothing needs preserving.
    if (byteCount > _obstacleBufferSize)
    {
      EnqueueGrowObstacles(byteCount);
    }

    Buffer.BlockCopy(_obstacleStaging, 0, _obstacleBytes, 0, byteCount);
    EnqueueGpuWrite(GpuTarget.Obstacles, 0, _obstacleBytes.AsSpan(0, byteCount));
  }

  private static void FindCollisionShapes(Node node, List<CollisionShape3D> results)
  {
    // Shapes with trigger metadata are pass-through — exclude them from the solid
    // obstacle GPU buffer so hogs walk through them freely.
    // Use IsVisibleInTree() so toggling a parent body correctly excludes all its shapes.
    if (
      node is CollisionShape3D { Shape: not null } cs
      && cs.IsVisibleInTree()
      && !cs.HasMeta("damage")
      && !cs.HasMeta("multiply")
      && !cs.HasMeta("add")
    )
    {
      results.Add(cs);
    }

    foreach (var child in node.GetChildren())
    {
      FindCollisionShapes(child, results);
    }
  }

  private static (Vector2 center, Vector2 halfExtents, float angle) ComputeMinObb(
    Vector3[] points3D,
    Transform3D xform
  )
  {
    // Project to x-z plane in world space
    var pts = new Vector2[points3D.Length];
    for (var i = 0; i < points3D.Length; i++)
    {
      var w = xform * points3D[i];
      pts[i] = new Vector2(w.X, w.Z);
    }

    var bestArea = float.MaxValue;
    var bestCenter = Vector2.Zero;
    var bestHalf = Vector2.Zero;
    var bestAngle = 0f;

    // Try OBB aligned to each edge
    for (var i = 0; i < pts.Length; i++)
    {
      var edge = pts[(i + 1) % pts.Length] - pts[i];
      var angle = Mathf.Atan2(edge.Y, edge.X);
      var c = Mathf.Cos(-angle);
      var s = Mathf.Sin(-angle);

      var minX = float.MaxValue;
      var maxX = float.MinValue;
      var minY = float.MaxValue;
      var maxY = float.MinValue;

      foreach (var p in pts)
      {
        var rx = (p.X * c) - (p.Y * s);
        var ry = (p.X * s) + (p.Y * c);
        minX = Mathf.Min(minX, rx);
        maxX = Mathf.Max(maxX, rx);
        minY = Mathf.Min(minY, ry);
        maxY = Mathf.Max(maxY, ry);
      }

      var area = (maxX - minX) * (maxY - minY);
      if (area < bestArea)
      {
        bestArea = area;
        bestHalf = new Vector2((maxX - minX) * 0.5f, (maxY - minY) * 0.5f);
        var cx = (minX + maxX) * 0.5f;
        var cy = (minY + maxY) * 0.5f;
        // Rotate center back to world space
        var c2 = Mathf.Cos(angle);
        var s2 = Mathf.Sin(angle);
        bestCenter = new Vector2((cx * c2) - (cy * s2), (cx * s2) + (cy * c2));
        bestAngle = angle;
      }
    }

    return (bestCenter, bestHalf, bestAngle);
  }
}
