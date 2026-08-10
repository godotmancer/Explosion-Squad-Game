namespace ExplosionSquadGame.ui;

using Godot;

/// <summary>
/// Draws a 2-D parabolic arc overlay and animates an optional 3-D projectile
/// scene along the trajectory between two Node3D markers.
///
/// Wire in the editor:
///   Source   → the projectile spawn Marker3D
///   Target   → any Node3D whose GlobalPosition is the aim point
///   Camera   → the scene Camera3D used for screen-space projection
///   Hud      → the CanvasLayer the 2-D arc drawer is added to
///   ProjectileScene → optional PackedScene (Node3D root) to animate
/// </summary>
[GlobalClass]
public partial class TrajectoryOverlay : Node3D
{
  [Export]
  public Camera3D Camera { get; set; }

  [Export]
  public Node3D Source { get; set; }

  [Export]
  public Node3D Target { get; set; }

  [Export]
  public CanvasLayer Hud { get; set; }

  [Export]
  public PackedScene ProjectileScene { get; set; }

  [ExportGroup("Physics")]
  [Export]
  public float ProjectileSpeed { get; set; } = 30f;

  [Export]
  public float Gravity { get; set; } = 9.8f;

  [Export]
  public float YOffset { get; set; } = -0.3f;

  // ---- Pre-allocated arc buffer (zero per-frame heap allocation) ----
  private const int MaxSteps = 120;
  private const float Dt = 0.05f;
  private readonly Vector3[] _arcPoints = new Vector3[MaxSteps];
  private int _arcCount;

  private Node3D _projectileInstance;
  private ArcDrawer _arcDrawer;
  private float _animTime;

  public override void _Ready()
  {
    if (ProjectileScene != null)
    {
      _projectileInstance = ProjectileScene.Instantiate<Node3D>();
      AddChild(_projectileInstance);
    }

    _arcDrawer = new ArcDrawer(this);
    (Hud ?? (Node)GetViewport()).AddChild(_arcDrawer);
  }

  public override void _Process(double delta)
  {
    if (Source != null && Target != null && Camera != null)
    {
      RebuildArc();

      if (_projectileInstance != null && _arcCount > 1)
      {
        var duration = _arcCount * Dt;
        _animTime = (_animTime + (float)delta) % duration;
        AnimateProjectile();
      }

      _arcDrawer?.QueueRedraw();
    }
  }

  // -------------------------------------------------------------------------
  // Simulate the parabolic trajectory and store world-space points
  // -------------------------------------------------------------------------
  private void RebuildArc()
  {
    var from = Source.GlobalPosition;
    var to = Target.GlobalPosition;
    var dir = (to - from).Normalized();
    var vel = dir * ProjectileSpeed;
    var pos = from;

    _arcCount = 0;
    for (var i = 0; i < MaxSteps; i++)
    {
      _arcPoints[i] = pos;
      _arcCount++;

      vel.Y -= Gravity * Dt;
      pos += vel * Dt;

      if (pos.Y >= YOffset)
      {
        continue;
      }
      break;
    }
  }

  // -------------------------------------------------------------------------
  // Move and orient the animated projectile instance along the arc
  // -------------------------------------------------------------------------
  private void AnimateProjectile()
  {
    var stepF = _animTime / Dt;
    var idx = Mathf.Clamp((int)stepF, 0, _arcCount - 2);
    var frac = stepF - idx;

    var p = _arcPoints[idx].Lerp(_arcPoints[idx + 1], frac);
    _projectileInstance.GlobalPosition = p;

    var forward = (_arcPoints[idx + 1] - _arcPoints[idx]).Normalized();
    if (forward.LengthSquared() > 0.001f)
    {
      // Avoid degenerate LookAt when forward is nearly vertical
      var up = Mathf.Abs(forward.Dot(Vector3.Up)) > 0.99f ? Vector3.Forward : Vector3.Up;
      _projectileInstance.LookAt(p + forward, up);
    }
  }

  // -------------------------------------------------------------------------
  // Inner Control — projects arc points to screen and draws the 2-D overlay
  // -------------------------------------------------------------------------
  private sealed partial class ArcDrawer : Control
  {
    private readonly TrajectoryOverlay _owner;

    public ArcDrawer(TrajectoryOverlay owner)
    {
      _owner = owner;
      MouseFilter = MouseFilterEnum.Ignore;
    }

    public ArcDrawer() { }

    public override void _Draw()
    {
      var camera = _owner.Camera;
      if (camera != null && _owner._arcCount >= 2)
      {
        // CanvasLayer has no rect — set size to viewport every draw call
        Size = GetViewport().GetVisibleRect().Size;

        Vector2? prev = null;
        for (var i = 0; i < _owner._arcCount; i++)
        {
          var p = _owner._arcPoints[i];
          if (camera.IsPositionBehind(p))
          {
            prev = null;
            continue;
          }

          var screen = camera.UnprojectPosition(p);
          var alpha = 1.0f - ((float)i / _owner._arcCount);

          if (prev.HasValue)
          {
            DrawLine(prev.Value, screen, new Color(1f, 0.55f, 0.1f, alpha), 2f);
          }

          prev = screen;
        }

        // Impact marker at last arc point
        var last = _owner._arcPoints[_owner._arcCount - 1];
        if (camera.IsPositionBehind(last))
        {
          return;
        }

        var ts = camera.UnprojectPosition(last);
        DrawCircle(ts, 6f, new Color(1f, 0.3f, 0.1f, 0.9f));
        DrawArc(ts, 14f, 0f, Mathf.Tau, 24, new Color(1f, 0.3f, 0.1f, 0.5f), 1.5f);
      }
    }
  }
}
