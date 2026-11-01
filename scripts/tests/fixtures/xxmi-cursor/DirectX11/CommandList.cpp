// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Verbatim excerpt from XXMI-Libs-Package v1.2.2 (commit a7847eae82aaac32175c9a7d199673d5c9323bcd), GPL-3.0-only.
// Source: https://github.com/SpectrumQT/XXMI-Libs-Package
// Minimal offline fixture for the SRMI cursor contract regression. See PROVENANCE.json.
// Do not edit the excerpted source lines by hand.
CommandListState::CommandListState() :
	mHackerDevice(NULL),
	mHackerContext(NULL),
	mOrigDevice1(NULL),
	mOrigContext1(NULL),
	rt_width(-1),
	rt_height(-1),
	call_info(NULL),
	this_target(NULL),
	resource(NULL),
	view(NULL),
	post(false),
	update_params(false),
	cursor_mask_tex(NULL),
	cursor_mask_view(NULL),
	cursor_color_tex(NULL),
	cursor_color_view(NULL),
	recursion(0),
	extra_indent(0),
	aborted(false),
	scissor_valid(false)
{
	memset(&cursor_info, 0, sizeof(CURSORINFO));
	memset(&cursor_info_ex, 0, sizeof(ICONINFO));
	memset(&window_rect, 0, sizeof(RECT));
}

CommandListState::~CommandListState()
{
	if (cursor_info_ex.hbmMask)
		DeleteObject(cursor_info_ex.hbmMask);
	if (cursor_info_ex.hbmColor)
		DeleteObject(cursor_info_ex.hbmColor);
	if (cursor_mask_view)
		cursor_mask_view->Release();
	if (cursor_mask_tex)
		cursor_mask_tex->Release();
	if (cursor_color_view)
		cursor_color_view->Release();
	if (cursor_color_tex)
		cursor_color_tex->Release();
}

#pragma endregion CommandListRuntimePart2


#pragma region WindowCursorHelpers

static void UpdateWindowInfo(CommandListState *state)
{
	if (state->window_rect.right)
		return;

	if (G->hWnd)
		CursorUpscalingBypass_GetClientRect(G->hWnd, &state->window_rect);
	else
		LogDebug("UpdateWindowInfo: No hWnd\n");
}

static void UpdateCursorInfo(CommandListState *state)
{
	if (state->cursor_info.cbSize)
		return;

	state->cursor_info.cbSize = sizeof(CURSORINFO);
	CursorUpscalingBypass_GetCursorInfo(&state->cursor_info);
	memcpy(&state->cursor_window_coords, &state->cursor_info.ptScreenPos, sizeof(POINT));

	if (G->hWnd)
		CursorUpscalingBypass_ScreenToClient(G->hWnd, &state->cursor_window_coords);
	else
		LogDebug("UpdateCursorInfo: No hWnd\n");
}

static void UpdateCursorInfoEx(CommandListState *state)
{
	if (state->cursor_info_ex.hbmMask)
		return;

	UpdateCursorInfo(state);

	GetIconInfo(state->cursor_info.hCursor, &state->cursor_info_ex);
}
// --- verbatim source excerpt gap ---
static float HeuristicGetWindowWidth(CommandListState* state)
{
	float fret;
	// Try to get width from window_rect
	UpdateWindowInfo(state);
	fret = (float)state->window_rect.right;
	if (fret >= 640) {
		return fret;
	}
	// Fallback to RES_WIDTH
	fret = (float)G->mResolutionInfo.width;
	if (fret >= 640) {
		return fret;
	}
	// Fallback to RT_WIDTH
	ProcessParamRTSize(state);
	fret = state->rt_width;
	if (fret >= 640) {
		return fret;

	}
	// All methods failed, return fallback width
	return (float)G->gFallbackScreenWidth;
}

static float HeuristicGetWindowHeight(CommandListState* state)
{
	float fret;
	// Try to get height from window_rect
	UpdateWindowInfo(state);
	fret = (float)state->window_rect.bottom;
	if (fret >= 480) {
		return fret;
	}
	// Fallback to RES_HEIGHT
	fret = (float)G->mResolutionInfo.height;
	if (fret >= 480) {
		return fret;
	}
	// Fallback to RT_HEIGHT
	ProcessParamRTSize(state);
	fret = state->rt_height;
	if (fret >= 480) {
		return fret;
	}
	// All methods failed, return fallback height
	return (float)G->gFallbackScreenHeight;
}

#pragma endregion WindowCursorHelpers


#pragma region CommandListRuntimePart3

float CommandListOperand::evaluate(CommandListState *state, HackerDevice *device)
{
	float ftemp;
	float fret;

	if (state)
		device = state->mHackerDevice;
	else if (!device) {
		LogOverlay(LOG_DIRE, "BUG: CommandListOperand::evaluate called with neither state nor device\n");
		return 0;
	}

	// XXX: If updating this list, be sure to also update
	// XXX: operand_allowed_in_context()
	switch (type) {
		case ParamOverrideType::VALUE:
			return val;
		case ParamOverrideType::INI_PARAM:
			return G->iniParams[param_idx].*param_component;
		case ParamOverrideType::VARIABLE:
			return *var_ftarget;
		case ParamOverrideType::RES_WIDTH:
			return (float)G->mResolutionInfo.width;
		case ParamOverrideType::RES_HEIGHT:
			return (float)G->mResolutionInfo.height;
		case ParamOverrideType::TIME:
			return G->gTime;
		case ParamOverrideType::FRAME_TIME:
			return G->gFrameTime;
		case ParamOverrideType::FPS:
			return G->gFPSCounter.GetFPS();
		case ParamOverrideType::FRAME_NUMBER:
			return (float)G->frame_no;
		case ParamOverrideType::HUNTING:
			return (float)G->hunting;
		case ParamOverrideType::FRAME_ANALYSIS:
			return G->analyse_frame;
		case ParamOverrideType::EFFECTIVE_DPI:
			return get_effective_dpi();
		case ParamOverrideType::SLI:
			return 0;
		case ParamOverrideType::STEREO_ACTIVE:
			return 0;
		case ParamOverrideType::STEREO_AVAILABLE:
			return 0;
		// XXX: If updating this list, be sure to also update
		// XXX: operand_allowed_in_context()
	}

	if (!state) {
		// FIXME: Some of these only use the state object for cache,
		// and could still be evaluated if we forgo the cache
		LogOverlay(LOG_WARNING, "BUG: Operand type %i cannot be evaluated outside of a command list\n", type);
		return 0;
	}

	switch (type) {
		case ParamOverrideType::RT_WIDTH:
			ProcessParamRTSize(state);
			return state->rt_width;
		case ParamOverrideType::RT_HEIGHT:
			ProcessParamRTSize(state);
			return state->rt_height;
		case ParamOverrideType::WINDOW_WIDTH:
			return HeuristicGetWindowWidth(state);
		case ParamOverrideType::WINDOW_HEIGHT:
			return HeuristicGetWindowHeight(state);
		case ParamOverrideType::TEXTURE:
			return process_texture_filter(state);
		case ParamOverrideType::SHADER:
			return process_shader_filter(state);
		case ParamOverrideType::VERTEX_COUNT:
			if (state->call_info)
				return (float)state->call_info->VertexCount;
			return 0;
		case ParamOverrideType::INDEX_COUNT:
			if (state->call_info)
				return (float)state->call_info->IndexCount;
			return 0;
		case ParamOverrideType::INSTANCE_COUNT:
			if (state->call_info)
				return (float)state->call_info->InstanceCount;
			return 0;
		case ParamOverrideType::FIRST_VERTEX:
			if (state->call_info)
				return (float)state->call_info->FirstVertex;
			return 0;
		case ParamOverrideType::FIRST_INDEX:
			if (state->call_info)
				return (float)state->call_info->FirstIndex;
			return 0;
		case ParamOverrideType::FIRST_INSTANCE:
			if (state->call_info)
				return (float)state->call_info->FirstInstance;
			return 0;
		case ParamOverrideType::THREAD_GROUP_COUNT_X:
			if (state->call_info)
				return (float)state->call_info->ThreadGroupCountX;
			return 0;
		case ParamOverrideType::THREAD_GROUP_COUNT_Y:
			if (state->call_info)
				return (float)state->call_info->ThreadGroupCountY;
			return 0;
		case ParamOverrideType::THREAD_GROUP_COUNT_Z:
			if (state->call_info)
				return (float)state->call_info->ThreadGroupCountZ;
			return 0;
		case ParamOverrideType::INDIRECT_OFFSET:
			if (state->call_info)
				return (float)state->call_info->args_offset;
			return 0;
		case ParamOverrideType::DRAW_TYPE:
			if (state->call_info)
				return (float)state->call_info->type;
			return 0;
		case ParamOverrideType::CURSOR_VISIBLE:
			UpdateCursorInfo(state);
			return !!(state->cursor_info.flags & CURSOR_SHOWING);
		case ParamOverrideType::CURSOR_SCREEN_X:
			UpdateCursorInfo(state);
			return (float)state->cursor_info.ptScreenPos.x;
		case ParamOverrideType::CURSOR_SCREEN_Y:
			UpdateCursorInfo(state);
			return (float)state->cursor_info.ptScreenPos.y;
		case ParamOverrideType::CURSOR_WINDOW_X:
			UpdateCursorInfo(state);
			return (float)state->cursor_window_coords.x;
		case ParamOverrideType::CURSOR_WINDOW_Y:
			UpdateCursorInfo(state);
			return (float)state->cursor_window_coords.y;
		case ParamOverrideType::CURSOR_X:
			UpdateCursorInfo(state);
			ftemp = HeuristicGetWindowWidth(state);
			// Try to get cursor X from cursor_window_coords
			fret = (float)state->cursor_window_coords.x / ftemp;
			if (abs(fret) > 0.000001) {
				return fret;
			}
			// Fallback to CURSOR_SCREEN_X
			fret = (float)state->cursor_info.ptScreenPos.x / ftemp;
			if (abs(fret) > 0.000001) {
				return fret;
			}
			// All methods failed, return zero
			return 0;
		case ParamOverrideType::CURSOR_Y:
			UpdateCursorInfo(state);
			ftemp = HeuristicGetWindowHeight(state);
			// Try to get cursor Y from cursor_window_coords
			fret = (float)state->cursor_window_coords.y / ftemp;
			if (abs(fret) > 0.000001) {
				return fret;
			}
			// Fallback to CURSOR_SCREEN_Y
			fret = (float)state->cursor_info.ptScreenPos.y / ftemp;
			if (abs(fret) > 0.000001) {
				return fret;
			}
			// All methods failed, return zero
			return 0;
		case ParamOverrideType::CURSOR_HOTSPOT_X:
			UpdateCursorInfoEx(state);
			return (float)state->cursor_info_ex.xHotspot;
		case ParamOverrideType::CURSOR_HOTSPOT_Y:
			UpdateCursorInfoEx(state);
			return (float)state->cursor_info_ex.yHotspot;
		case ParamOverrideType::SCISSOR_LEFT:
			UpdateScissorInfo(state);
			return (float)state->scissor_rects[scissor].left;
		case ParamOverrideType::SCISSOR_TOP:
			UpdateScissorInfo(state);
			return (float)state->scissor_rects[scissor].top;
