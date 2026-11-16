// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Minimal authenticated excerpt of XXMI-Libs-Package v1.2.3 (commit 065dc746c21c71ef48bbc93cb6b90b3dcdf766e6),
// GPL-3.0-only, for the SRMI disassembly exception fail-closed regression test.
// Blocks are verbatim source line ranges; separator lines mark gaps.
// Do not edit by hand: see PROVENANCE.json and test_xxmi_disassembly_guard.py.
// Common routine to handle disassembling binary shaders to asm text.
// This is used whenever we need the Asm text.


// New version using Flugan's wrapper around D3DDisassemble to replace the
// problematic %f floating point values with %.9e, which is enough that a 32bit
// floating point value will be reproduced exactly:
static string BinaryToAsmText(const void *pShaderBytecode, size_t BytecodeLength,
		bool patch_cb_offsets,
		bool disassemble_undecipherable_data = true,
		int hexdump = 0, bool d3dcompiler_46_compat = true)
{
	string comments;
	vector<byte> byteCode(BytecodeLength);
	vector<byte> disassembly;
	HRESULT r;

	comments = "//   using 3Dmigoto v" + string(VER_FILE_VERSION_STR) + " on " + LogTime() + "//\n";
	memcpy(byteCode.data(), pShaderBytecode, BytecodeLength);

#if MIGOTO_DX == 9
	r = disassemblerDX9(&byteCode, &disassembly, comments.c_str());
#elif MIGOTO_DX == 11
	r = disassembler(&byteCode, &disassembly, comments.c_str(), hexdump,
			d3dcompiler_46_compat, disassemble_undecipherable_data, patch_cb_offsets);
#endif // MIGOTO_DX
	if (FAILED(r)) {
		LogInfo("  disassembly failed. Error: %x\n", r);
		return "";
	}

	return string(disassembly.begin(), disassembly.end());
}
