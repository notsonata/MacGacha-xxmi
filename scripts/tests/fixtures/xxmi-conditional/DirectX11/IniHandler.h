// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Minimal authenticated excerpt of XXMI-Libs-Package v1.2.2 (commit a7847eae82aaac32175c9a7d199673d5c9323bcd),
// GPL-3.0-only, for the SRMI conditional-flow regression test.
// Blocks are verbatim source line ranges; separator lines mark gaps.
// Do not edit by hand: see PROVENANCE.json and test_xxmi_conditional_contract.py.
struct IniLine {
	// Same syntax as std::pair, whitespace stripped around each:
	wstring first;
	wstring second;

	// For when we don't want whitespace around the equals sign stripped,
	// or when there is no equals sign (whitespace at the start and end of
	// the whole line is still stripped):
	wstring raw_line;

	// Namespaced sections can determine the namespace from the section as
	// a whole, but global sections like [Present] can have lines from many
	// different namespaces, so each line stores the namespace it came from
	// to resolve references within the namespace:
	wstring ini_namespace;

	IniLine(wstring &key, wstring &val, wstring &line, const wstring &ini_namespace) :
		first(key),
		second(val),
		raw_line(line),
		ini_namespace(ini_namespace)
	{}
};

// Whereas settings within a section are in the same order they were in the ini
// file. This will become more important as shader overrides gains more
// functionality and dependencies between different features form:
typedef std::vector<IniLine> IniSectionVector;
