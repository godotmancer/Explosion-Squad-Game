namespace ExplosionSquadGame.bombs;

using Godot;

public partial class BombSpawner : Node
{
  [Export]
  public Camera3D Camera { get; set; }

  [Export]
  public PackedScene BombScene { get; set; }

  // Given your known X and Z world coordinates
  private float GetSpawnY(float targetX, float targetZ)
  {
    // 1. Get the camera's frustum planes
    // Godot's GetFrustum returns a special Godot Collections Array
    var planes = Camera.GetFrustum();

    // In Godot, the top plane is typically at index 3 in the frustum array
    // (Order: 0:Near, 1:Far, 2:Left, 3:Top, 4:Right, 5:Bottom)
    var topPlane = planes[3];

    // 2. Create a ray pointing straight UP from your X and Z coordinates
    // We use Y = 0 as an arbitrary starting point for the ray origin
    var rayOrigin = new Vector3(targetX, 0, targetZ);
    var rayDirection = Vector3.Up; // (0, 1, 0)

    // 3. Find where this vertical line intersects the top plane of the camera
    // IntersectsRay returns a nullable Vector3 (Vector3?)
    var intersection = topPlane.IntersectsRay(rayOrigin, rayDirection);

    if (intersection.HasValue)
    {
      // Add a small buffer (e.g., 1.0f units) so the bomb spawns completely off-screen,
      // not exactly half-clipping through the edge.
      var spawnBuffer = 1.0f;
      return intersection.Value.Y + spawnBuffer;
    }
    else
    {
      // Fallback in case the ray is somehow parallel to the top plane
      // (e.g. if the camera is looking straight down/up)
      GD.PushWarning("Ray did not intersect the top plane. Using fallback Y.");
      return Camera.GlobalPosition.Y + 10.0f;
    }
  }

  public void SpawnBomb(Vector3 finalGlobalPosition, Callable dropBombAction)
  {
    var spawnY = GetSpawnY(finalGlobalPosition.X, finalGlobalPosition.Z);
    var startSpawnPosition = new Vector3(finalGlobalPosition.X, spawnY, finalGlobalPosition.Z);

    // Instantiate the bomb scene. We assume the root node of the bomb is a Node3D.
    var bombInstance = BombScene.Instantiate<Node3D>();

    // Set the final global position
    bombInstance.Set("final_global_position", finalGlobalPosition);
    bombInstance.Set("drop_bomb_action", dropBombAction);

    // Add to the active scene tree.
    // Note: Adding directly to GetTree().Root works, but often it's better to add
    // to a specific container node like a "Level" or "Projectiles" node.
    GetTree().Root.AddChild(bombInstance);

    // Set the start global position
    bombInstance.GlobalPosition = startSpawnPosition;
  }
}
