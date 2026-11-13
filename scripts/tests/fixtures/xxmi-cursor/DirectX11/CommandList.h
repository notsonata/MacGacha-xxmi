// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Verbatim excerpt from XXMI-Libs-Package v1.2.3 (commit 065dc746c21c71ef48bbc93cb6b90b3dcdf766e6), GPL-3.0-only.
// Source: https://github.com/SpectrumQT/XXMI-Libs-Package
// Minimal offline fixture for the SRMI cursor contract regression. See PROVENANCE.json.
// Do not edit the excerpted source lines by hand.
class CommandListState {
public:
	HackerDevice *mHackerDevice;
	HackerContext *mHackerContext;
	ID3D11Device1 *mOrigDevice1;
	ID3D11DeviceContext1 *mOrigContext1;

	// Used to avoid querying the render target dimensions twice in the
	// common case we are going to store both width & height in separate
	// ini params:
	float rt_width, rt_height;
	DrawCallInfo *call_info;
	bool post;
	bool aborted;

	bool scissor_valid;
	D3D11_RECT scissor_rects[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE];

	// If set this resource is in some way related to the command list
	// invocation - a constant buffer we are analysing, a render target
	// being cleared, etc.
	ResourceCopyTarget *this_target;
	ID3D11Resource **resource;
	ID3D11View *view;
	std::vector<InputLayoutElementOverride*> input_layout_overrides;

	// TODO: Cursor info and resources would be better off being cached
	// somewhere that is updated at most once per frame rather than once
	// per command list execution, and we would ideally skip the resource
	// creation if the cursor is unchanged.
	CURSORINFO cursor_info;
	POINT cursor_window_coords;
	ICONINFO cursor_info_ex;
	ID3D11Texture2D *cursor_mask_tex;
	ID3D11Texture2D *cursor_color_tex;
	ID3D11ShaderResourceView *cursor_mask_view;
	ID3D11ShaderResourceView *cursor_color_view;
	RECT window_rect;

	int recursion;
	int extra_indent;
	LARGE_INTEGER profiling_time_recursive;

	// Anything that needs to be updated at the end of the command list:
	bool update_params;

	CommandListState();
	~CommandListState();
};
// --- verbatim source excerpt gap ---
enum class ParamOverrideType {
	INVALID,
	VALUE,
	INI_PARAM,
	VARIABLE,
	RT_WIDTH,
	RT_HEIGHT,
	RES_WIDTH,
	RES_HEIGHT,
	WINDOW_WIDTH,
	WINDOW_HEIGHT,
	TEXTURE,	// Needs shader type and slot number specified in
	SHADER,		// [ShaderOverride]. [TextureOverride] sections can
			// specify filter_index=N to define the value passed in
			// here. Special values for no [TextureOverride]
			// section = 0.0, or [TextureOverride] with no
			// filter_index = 1.0
	VERTEX_COUNT,
	INDEX_COUNT,
	INSTANCE_COUNT,
	FIRST_VERTEX,
	FIRST_INDEX,
	FIRST_INSTANCE,
	THREAD_GROUP_COUNT_X,
	THREAD_GROUP_COUNT_Y,
	THREAD_GROUP_COUNT_Z,
	INDIRECT_OFFSET,
	DRAW_TYPE,
	CURSOR_VISIBLE,
	CURSOR_SCREEN_X, // Cursor in screen coordinates in pixels
	CURSOR_SCREEN_Y,
	CURSOR_WINDOW_X, // Cursor in window client area coordinates in pixels
	CURSOR_WINDOW_Y,
	CURSOR_X,        // Cursor position scaled so that client area is the range [0:1]
	CURSOR_Y,
	CURSOR_HOTSPOT_X,
	CURSOR_HOTSPOT_Y,
	TIME,
	SCISSOR_LEFT,   // May have an optional scissor rectangle index
	SCISSOR_TOP,    // specified, which is parsed in code, or not -
	SCISSOR_RIGHT,  // in which case it will match the keyword list
	SCISSOR_BOTTOM,
	HUNTING,
	FRAME_ANALYSIS,
	EFFECTIVE_DPI, // For calculating UI scaling factor on 4K+. Note not the same thing as raw DPI.
	SLI,
	STEREO_ACTIVE,
	STEREO_AVAILABLE,
	FRAME_NUMBER,
	DRAW_NUMBER,
	DISPATCH_NUMBER,
	FRAME_TIME,
	FPS,
};
