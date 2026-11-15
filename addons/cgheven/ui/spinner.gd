@tool
extends Control
## Small rotating arc shown in the asset grid while assets are loading.
## Only animates while it is visible, so it costs nothing when idle.

var _angle := 0.0

func _init() -> void:
	custom_minimum_size = Vector2(44, 44)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	visibility_changed.connect(func(): set_process(is_visible_in_tree()))
	set_process(is_visible_in_tree())

func _process(delta: float) -> void:
	_angle = fmod(_angle + delta * 5.0, TAU)
	queue_redraw()

func _draw() -> void:
	var c := size / 2.0
	var r := minf(size.x, size.y) / 2.0 - 4.0
	if r <= 0.0:
		return
	draw_arc(c, r, 0.0, TAU, 48, Color(1, 1, 1, 0.08), 4.0, true)            # faint track
	draw_arc(c, r, _angle, _angle + TAU * 0.28, 24, CghConfig.C_BRAND, 4.0, true)   # moving arc
