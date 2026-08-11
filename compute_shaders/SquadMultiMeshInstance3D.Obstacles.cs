namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Collections.Generic;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  // --- Trimesh footprint decomposition tuning (ConcavePolygonShape3D → N OBBs) ---
  //
  // Grid lines come from the vertex coordinates themselves, so a rectilinear footprint
  // (what a CSG bake produces) is reproduced exactly.  MAX_SLABS caps the cell count for
  // organic meshes with many distinct coordinates; past the cap an axis falls back to a
  // uniform subdivision, which stair-steps the footprint instead.
  private const int FOOTPRINT_MAX_SLABS = 24;

  // Every emitted rect is another iteration of the shader's per-body obstacle loops,
  // so a pathological mesh must not be allowed to flood the buffer.
  private const int FOOTPRINT_MAX_RECTS = 32;
  private const float FOOTPRINT_WELD_EPS = 0.01f;
  private const float FOOTPRINT_AREA_EPS = 1e-6f;

  /// <summary>
  /// One axis-aligned rectangle of a trimesh's X-Z footprint, in shape-local space.
  /// </summary>
  private readonly record struct FootprintRect(Vector2 Center, Vector2 HalfExtents);

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
    // A shape can emit more than one obstacle (a trimesh emits one OBB per footprint
    // rectangle), so ask each one how many slots it needs, then trim to what was
    // actually written.
    var staticFloats = 0;
    foreach (var cs in _staticShapes)
    {
      staticFloats += ObstacleSlotCount(cs) * OBSTACLE_STRIDE;
    }

    var staticData = new float[staticFloats];
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

    // Calculate required capacity — movable shapes can emit more than one obstacle each.
    var movableFloats = 0;
    foreach (var cs in _movableShapes)
    {
      movableFloats += ObstacleSlotCount(cs) * OBSTACLE_STRIDE;
    }

    EnsureObstacleStagingCapacity(_staticObstacleData.Length + movableFloats);

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
      {
        // A trimesh is concave by definition: one OBB over the whole thing would fill in
        // every hole, so hogs would skirt a play pen instead of walking into it.  Emit one
        // OBB per rectangle of the decomposed footprint instead.
        var rects = GetConcaveFootprint(concave);
        if (rects.Length == 0)
        {
          // Nothing to decompose (a flat, edge-on mesh has no footprint) — fall back to a
          // single OBB so the shape is not silently dropped.
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
        }

        // Every rect is axis-aligned in shape-local space, so they all share the shape's
        // own Y rotation and only the centre needs the full transform.  Half extents pick
        // up the basis scale of the matching local axis.
        // Note: angular_vel is applied about each rect's own centre by the shader, so an
        // off-centre rect on a spinning trimesh under-reports its tangential surface speed
        // — the same approximation already used for shapes offset from a rotating parent.
        var scale = globalXform.Basis.Scale;
        foreach (var rect in rects)
        {
          var world = globalXform * new Vector3(rect.Center.X, 0f, rect.Center.Y);
          WriteObstacle(
            buffer,
            ref offset,
            world.X,
            world.Z,
            rect.HalfExtents.X * scale.X,
            rect.HalfExtents.Y * scale.Z,
            cosY,
            -sinY,
            linearVel.X,
            linearVel.Y,
            OBS_TYPE_OBB,
            ObstacleMargin,
            angularVel
          );
        }

        break;
      }
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

  /// <summary>
  /// Number of obstacle slots <paramref name="cs"/> will write. Must stay in sync with
  /// <see cref="EmitObstacleData"/> — it is what sizes the staging buffer before writing.
  /// </summary>
  private int ObstacleSlotCount(CollisionShape3D cs)
  {
    if (cs.Shape == null || cs.Disabled)
    {
      return 0;
    }

    return cs.Shape switch
    {
      // Max(_, 1) covers the degenerate-footprint fallback, which writes a single OBB.
      ConcavePolygonShape3D concave => Math.Max(GetConcaveFootprint(concave).Length, 1),
      SphereShape3D or CylinderShape3D or BoxShape3D or ConvexPolygonShape3D => 1,
      _ => 0,
    };
  }

  /// <summary>
  /// Returns the X-Z footprint decomposition of a trimesh shape, computing it on first use.
  /// Keyed on the shape resource: the rects are shape-local, so they stay valid as the
  /// obstacle moves and are shared by every instance using the same shape.  Caching also
  /// keeps <c>GetFaces()</c> (which allocates a fresh array) off the per-frame path for
  /// movable trimeshes.
  /// </summary>
  private FootprintRect[] GetConcaveFootprint(ConcavePolygonShape3D concave)
  {
    if (_concaveFootprints.TryGetValue(concave, out var cached))
    {
      return cached;
    }

    var rects = DecomposeTrimeshFootprint(concave.GetFaces());
    _concaveFootprints[concave] = rects;
    return rects;
  }

  /// <summary>
  /// Decomposes the X-Z footprint of a triangle soup into disjoint axis-aligned rectangles
  /// in shape-local space.
  ///
  /// Projecting every triangle of a closed mesh onto X-Z covers exactly its footprint: any
  /// point over solid geometry has a vertical line that exits through some triangle.  Holes
  /// (the inside of a pen, an archway) stay empty, because the vertical walls bounding them
  /// project to zero-area lines that are skipped.  So the footprint is recovered by
  /// rasterising the projected triangles onto a grid whose lines are the vertex coordinates
  /// themselves, then greedily merging solid cells into maximal rectangles.  For the
  /// rectilinear footprints CSG bakes produce, that reconstruction is exact.
  /// </summary>
  private static FootprintRect[] DecomposeTrimeshFootprint(Vector3[] faces)
  {
    if (faces.Length < 3)
    {
      return [];
    }

    var xs = BuildSlabEdges(faces, useX: true);
    var zs = BuildSlabEdges(faces, useX: false);
    var nx = xs.Length - 1;
    var nz = zs.Length - 1;

    if (nx < 1 || nz < 1)
    {
      return []; // flat in X or Z — no footprint to decompose
    }

    // Cell centres, reused by both the rasteriser and the merge pass.
    var cellX = new float[nx];
    for (var i = 0; i < nx; i++)
    {
      cellX[i] = (xs[i] + xs[i + 1]) * 0.5f;
    }

    var cellZ = new float[nz];
    for (var j = 0; j < nz; j++)
    {
      cellZ[j] = (zs[j] + zs[j + 1]) * 0.5f;
    }

    // ---- Rasterise: mark every cell whose centre falls inside a projected triangle ----
    var solid = new bool[nx * nz];
    for (var t = 0; t + 2 < faces.Length; t += 3)
    {
      var a = new Vector2(faces[t].X, faces[t].Z);
      var b = new Vector2(faces[t + 1].X, faces[t + 1].Z);
      var c = new Vector2(faces[t + 2].X, faces[t + 2].Z);

      var area2 = ((b.X - a.X) * (c.Y - a.Y)) - ((b.Y - a.Y) * (c.X - a.X));
      if (Mathf.Abs(area2) < FOOTPRINT_AREA_EPS)
      {
        continue; // edge-on triangle (a vertical wall) — contributes no footprint
      }

      // Bounds reject so each triangle only visits the cells it can possibly cover.
      var minX = Mathf.Min(a.X, Mathf.Min(b.X, c.X));
      var maxX = Mathf.Max(a.X, Mathf.Max(b.X, c.X));
      var minZ = Mathf.Min(a.Y, Mathf.Min(b.Y, c.Y));
      var maxZ = Mathf.Max(a.Y, Mathf.Max(b.Y, c.Y));

      for (var i = 0; i < nx; i++)
      {
        if (cellX[i] < minX || cellX[i] > maxX)
        {
          continue;
        }

        for (var j = 0; j < nz; j++)
        {
          var idx = (j * nx) + i;
          if (solid[idx] || cellZ[j] < minZ || cellZ[j] > maxZ)
          {
            continue;
          }

          if (PointInTriangle(new Vector2(cellX[i], cellZ[j]), a, b, c, area2))
          {
            solid[idx] = true;
          }
        }
      }
    }

    // ---- Greedy maximal-rectangle merge ----
    // Grow right along the row first, then down while the whole span stays solid.  Cells
    // have unequal sizes, but any block of them is still an axis-aligned rectangle.
    var rects = new List<FootprintRect>();
    var used = new bool[nx * nz];

    for (var j = 0; j < nz && rects.Count < FOOTPRINT_MAX_RECTS; j++)
    {
      for (var i = 0; i < nx && rects.Count < FOOTPRINT_MAX_RECTS; i++)
      {
        if (!Free(solid, used, nx, i, j))
        {
          continue;
        }

        var w = 1;
        while (i + w < nx && Free(solid, used, nx, i + w, j))
        {
          w++;
        }

        var h = 1;
        while (j + h < nz && SpanFree(solid, used, nx, i, j + h, w))
        {
          h++;
        }

        for (var dj = 0; dj < h; dj++)
        {
          for (var di = 0; di < w; di++)
          {
            used[((j + dj) * nx) + i + di] = true;
          }
        }

        var x0 = xs[i];
        var x1 = xs[i + w];
        var z0 = zs[j];
        var z1 = zs[j + h];
        rects.Add(
          new FootprintRect(
            new Vector2((x0 + x1) * 0.5f, (z0 + z1) * 0.5f),
            new Vector2((x1 - x0) * 0.5f, (z1 - z0) * 0.5f)
          )
        );
      }
    }

    if (rects.Count >= FOOTPRINT_MAX_RECTS)
    {
      GD.PushWarning(
        $"Trimesh obstacle footprint hit the {FOOTPRINT_MAX_RECTS}-rectangle cap; "
          + "part of the shape is not collidable. Split it into simpler obstacles."
      );
    }

    return [.. rects];
  }

  private static bool Free(bool[] solid, bool[] used, int nx, int i, int j)
  {
    var idx = (j * nx) + i;
    return solid[idx] && !used[idx];
  }

  private static bool SpanFree(bool[] solid, bool[] used, int nx, int i, int j, int w)
  {
    for (var k = 0; k < w; k++)
    {
      if (!Free(solid, used, nx, i + k, j))
      {
        return false;
      }
    }

    return true;
  }

  /// <summary>
  /// Grid lines for one axis: every distinct vertex coordinate, welded within
  /// <see cref="FOOTPRINT_WELD_EPS"/>.  Falls back to a uniform subdivision when a mesh has
  /// more distinct coordinates than <see cref="FOOTPRINT_MAX_SLABS"/> allows.
  /// </summary>
  private static float[] BuildSlabEdges(Vector3[] faces, bool useX)
  {
    var coords = new float[faces.Length];
    for (var i = 0; i < faces.Length; i++)
    {
      coords[i] = useX ? faces[i].X : faces[i].Z;
    }

    Array.Sort(coords);

    var edges = new List<float>();
    foreach (var c in coords)
    {
      if (edges.Count == 0 || c - edges[^1] > FOOTPRINT_WELD_EPS)
      {
        edges.Add(c);
      }
    }

    if (edges.Count <= FOOTPRINT_MAX_SLABS + 1)
    {
      return [.. edges];
    }

    // Organic mesh: too many distinct coordinates to give each one its own slab.  A uniform
    // grid keeps the cell count bounded at the cost of stair-stepping the footprint.
    GD.PushWarning(
      $"Trimesh obstacle has more than {FOOTPRINT_MAX_SLABS} distinct "
        + $"{(useX ? "X" : "Z")} coordinates; its footprint will be approximated on a "
        + "uniform grid."
    );

    var uniform = new float[FOOTPRINT_MAX_SLABS + 1];
    for (var i = 0; i <= FOOTPRINT_MAX_SLABS; i++)
    {
      uniform[i] = Mathf.Lerp(edges[0], edges[^1], (float)i / FOOTPRINT_MAX_SLABS);
    }

    return uniform;
  }

  private static bool PointInTriangle(Vector2 p, Vector2 a, Vector2 b, Vector2 c, float area2)
  {
    // area2 fixes the winding so the three edge cross-products can share one sign test.
    var w = area2 < 0f ? -1f : 1f;
    var d1 = (((b.X - a.X) * (p.Y - a.Y)) - ((b.Y - a.Y) * (p.X - a.X))) * w;
    var d2 = (((c.X - b.X) * (p.Y - b.Y)) - ((c.Y - b.Y) * (p.X - b.X))) * w;
    var d3 = (((a.X - c.X) * (p.Y - c.Y)) - ((a.Y - c.Y) * (p.X - c.X))) * w;
    return d1 >= 0f && d2 >= 0f && d3 >= 0f;
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
