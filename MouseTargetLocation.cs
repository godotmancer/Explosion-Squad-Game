namespace ExplosionSquadGame;

using Godot;

public partial class MouseTargetLocation : Node3D
{
  [Export]
  public Camera3D Camera { get; set; }

  public override void _Ready() { }

  public override void _UnhandledInput(InputEvent @event)
  {
    if (@event is InputEventScreenTouch eventScreenTouch)
    {
      GlobalPosition = GetVector3FromScreenPosition(eventScreenTouch.Position);
    }

    if (@event is InputEventMouseMotion eventMouseMotion)
    {
      GlobalPosition = GetVector3FromScreenPosition(eventMouseMotion.Position);
    }
  }

  private Vector3 GetVector3FromScreenPosition(Vector2 screenPos)
  {
    var origin = Camera.ProjectRayOrigin(screenPos);
    var direction = Camera.ProjectRayNormal(screenPos);

    if (Mathf.Abs(direction.Y) < 0.001f)
    {
      return Vector3.Zero;
    }

    var t = -origin.Y / direction.Y;
    if (t < 0)
    {
      return Vector3.Zero;
    }

    var hit = origin + (direction * t);
    return hit;
  }
}
