@tool
extends RefCounted
class_name CghTheme
## Builds a Godot Theme resource in code that matches the After Effects addon
## dark look 1:1 (StyleBoxFlat — rounded cards, dark bg, accent borders).

static func _box(bg: Color, radius: int, border := 0, border_col := Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 8
	if border > 0:
		sb.set_border_width_all(border)
		sb.border_color = border_col
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb

static func build() -> Theme:
	var t := Theme.new()

	# --- Panel / background ---
	t.set_stylebox("panel", "PanelContainer", _box(CghConfig.C_BG, 0))

	# --- Buttons (default = subtle, accent on hover) ---
	var btn_normal := _box(CghConfig.C_CARD, CghConfig.RADIUS_MD, 1, CghConfig.C_BORDER)
	var btn_hover := _box(CghConfig.C_CARD_HOVER, CghConfig.RADIUS_MD, 1, CghConfig.C_ACCENT)
	var btn_pressed := _box(CghConfig.C_ACCENT_DIM, CghConfig.RADIUS_MD, 1, CghConfig.C_ACCENT)
	t.set_stylebox("normal", "Button", btn_normal)
	t.set_stylebox("hover", "Button", btn_hover)
	t.set_stylebox("pressed", "Button", btn_pressed)
	t.set_stylebox("focus", "Button", _box(Color.TRANSPARENT, CghConfig.RADIUS_MD))
	t.set_color("font_color", "Button", CghConfig.C_TEXT1)
	t.set_color("font_hover_color", "Button", CghConfig.C_TEXT1)
	t.set_color("font_pressed_color", "Button", CghConfig.C_ACCENT_HOVER)

	# --- LineEdit (search box, key input) ---
	var le := _box(CghConfig.C_INPUT, CghConfig.RADIUS_MD, 1, CghConfig.C_BORDER)
	var le_focus := _box(CghConfig.C_INPUT, CghConfig.RADIUS_MD, 1, CghConfig.C_ACCENT)
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", le_focus)
	t.set_color("font_color", "LineEdit", CghConfig.C_TEXT1)
	t.set_color("font_placeholder_color", "LineEdit", CghConfig.C_TEXT3)
	t.set_color("caret_color", "LineEdit", CghConfig.C_ACCENT)

	# --- Labels ---
	t.set_color("font_color", "Label", CghConfig.C_TEXT1)

	# --- OptionButton (sort / format dropdowns) ---
	t.set_stylebox("normal", "OptionButton", btn_normal)
	t.set_stylebox("hover", "OptionButton", btn_hover)
	t.set_stylebox("pressed", "OptionButton", btn_pressed)
	t.set_color("font_color", "OptionButton", CghConfig.C_TEXT1)

	# --- ScrollContainer / grid background transparent over bg ---
	t.set_stylebox("panel", "ScrollContainer", _box(Color.TRANSPARENT, 0))

	# --- PopupMenu (dropdowns) ---
	t.set_stylebox("panel", "PopupMenu", _box(CghConfig.C_BG2, CghConfig.RADIUS_LG, 1, CghConfig.C_BORDER))
	t.set_color("font_color", "PopupMenu", CghConfig.C_TEXT1)
	t.set_color("font_hover_color", "PopupMenu", CghConfig.C_ACCENT_HOVER)

	return t

## Reusable styleboxes pulled by widgets (cards, badges, banner).
## AE card: background is ALWAYS #1e1e24 — hover only brightens the border
## (never recolors the card). This is what makes the grid look uniform.
static func card_box(hover := false) -> StyleBoxFlat:
	var border_col := CghConfig.C_BORDER_HOVER if hover else CghConfig.C_BORDER
	return _box(CghConfig.C_CARD, CghConfig.RADIUS_LG, 1, border_col)

static func accent_button_box(hover := false) -> StyleBoxFlat:
	var c := CghConfig.C_ACCENT_HOVER if hover else CghConfig.C_ACCENT
	return _box(c, CghConfig.RADIUS_MD)

## Orange brand button (Login / Sign up / Upgrade) — solid mid-gradient color.
static func brand_button_box(hover := false) -> StyleBoxFlat:
	var c := CghConfig.C_BRAND_HOVER if hover else CghConfig.C_BRAND
	return _box(c, CghConfig.RADIUS_MD)

## The AE .cdl-row footer pill (subtle grey, thin border, 4px radius).
static func footer_pill_box(hover := false) -> StyleBoxFlat:
	var border_col := Color(0.357, 0.486, 1.0, 0.35) if hover else CghConfig.C_BORDER
	var sb := _box(CghConfig.C_FOOTER_PILL, CghConfig.RADIUS_SM, 1, border_col)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	return sb

## Dropdown / popover background (--bgd #1c1c22).
static func dropdown_box() -> StyleBoxFlat:
	return _box(CghConfig.C_DROPDOWN, CghConfig.RADIUS_XL, 1, CghConfig.C_BORDER)

## Resolution badge — dark translucent pill, small radius (AE .rbadge).
static func res_badge_box() -> StyleBoxFlat:
	var sb := _box(CghConfig.C_RES_BADGE, 3)
	sb.content_margin_left = 5
	sb.content_margin_right = 5
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb

## Coloured badge (NEW = red, Premium = orange) — small 3px pill like AE.
static func badge_box(col: Color) -> StyleBoxFlat:
	var sb := _box(col, 3)
	sb.content_margin_left = 5
	sb.content_margin_right = 5
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb

static func banner_box() -> StyleBoxFlat:
	# brand gradient is approximated with a flat brand color (StyleBoxFlat has no gradient);
	# a true gradient uses a TextureRect with a GradientTexture2D behind the banner.
	return _box(CghConfig.C_BRAND_A, CghConfig.RADIUS_LG)
