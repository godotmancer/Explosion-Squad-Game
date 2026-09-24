namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  /// <summary>
  /// Uploads the live hogs of the latest readback to the MultiMesh, with a bounding box around
  /// them. With <see cref="FrustumCulling"/> on, only the hogs the camera can see (give or take
  /// <see cref="FrustumCullMargin"/>) are uploaded.
  ///
  /// Godot has no per-instance culling. It culls a MultiMesh as one object by its AABB, then
  /// draws all VisibleInstanceCount instances in every pass that AABB reaches: the depth
  /// prepass, the colour pass, each directional shadow cascade and the shadow maps of every
  /// shadowed light in range (six faces for an omni). The crowd spans the whole field, so that
  /// was every live hog in every pass, on screen or not.
  ///
  /// Runs from _Process, once per rendered frame, so it culls against the camera the frame
  /// renders from and uploads once however many ticks the frame ran. It uploads only when there
  /// is a new readback or the view has moved.
  /// </summary>
  private void DrawHogs()
  {
    if (_drawReadback == null)
    {
      return;
    }

    var camera = FrustumCulling ? GetViewport().GetCamera3D() : null;
    if (camera != null)
    {
      var view = camera.GetCameraTransform();
      var projection = camera.GetCameraProjection();
      var node = GlobalTransform;
      if (
        !_hogsDrawDirty
        && view == _drawnView
        && projection == _drawnProjection
        && node == _drawnNodeTransform
      )
      {
        return;
      }
      _drawnView = view;
      _drawnProjection = projection;
      _drawnNodeTransform = node;
      BuildCullPlanes(projection * new Projection(view.AffineInverse()), node);
    }
    else if (!_hogsDrawDirty)
    {
      return;
    }
    _hogsDrawDirty = false;

    ReadOnlySpan<float> src = MemoryMarshal.Cast<byte, float>(_drawReadback.AsSpan());
    var dst = _transformFloats.AsSpan();
    var bodyCount = src.Length / INSTANCE_STRIDE;

    // How far outside a plane a hog's origin may be and still have its mesh, or a shadow worth
    // keeping, reach into the view. Negative: the planes measure distance into the view.
    var reach = -(_hogBoundingRadius + FrustumCullMargin);
    var cull = camera != null;
    var left = _cullPlanes[0];
    var right = _cullPlanes[1];
    var bottom = _cullPlanes[2];
    var top = _cullPlanes[3];
    var near = _cullPlanes[4];
    var far = _cullPlanes[5];

    float minX = float.MaxValue, minY = float.MaxValue, minZ = float.MaxValue;
    float maxX = float.MinValue, maxY = float.MinValue, maxZ = float.MinValue;
    var drawn = 0;
    for (var i = 0; i < bodyCount; i++)
    {
      var o = i * INSTANCE_STRIDE;
      if ((BitConverter.SingleToUInt32Bits(src[o + INST_STATE]) & STATE_DEAD) != 0)
      {
        continue;
      }

      var x = src[o + INST_ORIGIN_X];
      var y = src[o + INST_ORIGIN_Y];
      var z = src[o + INST_ORIGIN_Z];
      if (
        cull
        && (
          IsOutside(left, x, y, z, reach)
          || IsOutside(right, x, y, z, reach)
          || IsOutside(bottom, x, y, z, reach)
          || IsOutside(top, x, y, z, reach)
          || IsOutside(near, x, y, z, reach)
          || IsOutside(far, x, y, z, reach)
        )
      )
      {
        continue;
      }

      src.Slice(o, INSTANCE_STRIDE).CopyTo(dst.Slice(drawn * INSTANCE_STRIDE, INSTANCE_STRIDE));
      drawn++;
      minX = Math.Min(minX, x);
      minY = Math.Min(minY, y);
      minZ = Math.Min(minZ, z);
      maxX = Math.Max(maxX, x);
      maxY = Math.Max(maxY, y);
      maxZ = Math.Max(maxZ, z);
    }

    // Our own AABB, set before the buffer: with none, MultimeshSetBuffer rebuilds one by
    // transforming the mesh bounds by every row of the buffer, the whole capacity, including
    // the stale rows past VisibleInstanceCount. It is also the box Godot culls the MultiMesh by
    // per light and cascade, so a tight one keeps the crowd out of shadow maps it cannot reach.
    var r = _hogBoundingRadius;
    var aabb =
      drawn > 0
        ? new Aabb(
          new Vector3(minX - r, minY - r, minZ - r),
          new Vector3(maxX - minX + 2 * r, maxY - minY + 2 * r, maxZ - minZ + 2 * r)
        )
        : new Aabb(Vector3.Zero, new Vector3(r, r, r)); // any non-empty box: nothing is drawn
    var rid = Multimesh.GetRid();
    RenderingServer.MultimeshSetCustomAabb(rid, aabb);
    Multimesh.VisibleInstanceCount = drawn;
    RenderingServer.MultimeshSetBuffer(rid, _transformFloats);
  }

  [MethodImpl(MethodImplOptions.AggressiveInlining)]
  private static bool IsOutside(Vector4 plane, float x, float y, float z, float reach) =>
    (plane.X * x) + (plane.Y * y) + (plane.Z * z) + plane.W < reach;

  /// <summary>
  /// Fills <see cref="_cullPlanes"/> from <paramref name="clip"/>, the camera's world-to-clip
  /// matrix. Godot's Projection keeps OpenGL clip space, where a point is in view when
  /// -w ≤ x, y, z ≤ w, so each plane of the view volume is row 3 of the matrix plus or minus
  /// one of the others (Gribb and Hartmann). The planes are then moved into the squad node's
  /// space, where the readback's positions are.
  /// </summary>
  private void BuildCullPlanes(Projection clip, Transform3D node)
  {
    // The matrix is stored by columns; row k is component k of each.
    var r0 = new Vector4(clip.X.X, clip.Y.X, clip.Z.X, clip.W.X);
    var r1 = new Vector4(clip.X.Y, clip.Y.Y, clip.Z.Y, clip.W.Y);
    var r2 = new Vector4(clip.X.Z, clip.Y.Z, clip.Z.Z, clip.W.Z);
    var r3 = new Vector4(clip.X.W, clip.Y.W, clip.Z.W, clip.W.W);

    // Sides first: they reject most of what is out of view, so the test stops sooner.
    _cullPlanes[0] = ToNodeSpace(r3 + r0, node); // left
    _cullPlanes[1] = ToNodeSpace(r3 - r0, node); // right
    _cullPlanes[2] = ToNodeSpace(r3 + r1, node); // bottom
    _cullPlanes[3] = ToNodeSpace(r3 - r1, node); // top
    _cullPlanes[4] = ToNodeSpace(r3 + r2, node); // near
    _cullPlanes[5] = ToNodeSpace(r3 - r2, node); // far
  }

  // Normalises a world-space plane so it measures metres, then rewrites it for points in the
  // node's space: with p_world = B·p + o, n·p_world + d = (Bᵀn)·p + (n·o + d). The result
  // still measures world metres, whatever the node's scale.
  private static Vector4 ToNodeSpace(Vector4 plane, Transform3D node)
  {
    var n = new Vector3(plane.X, plane.Y, plane.Z);
    var length = n.Length();
    n /= length;
    var local = n * node.Basis; // Bᵀn
    return new Vector4(local.X, local.Y, local.Z, n.Dot(node.Origin) + (plane.W / length));
  }
}
