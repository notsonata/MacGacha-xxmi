// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Minimal authenticated excerpt of XXMI-Libs-Package v1.2.2 (commit a7847eae82aaac32175c9a7d199673d5c9323bcd),
// GPL-3.0-only, for the SRMI conditional-flow regression test.
// Blocks are verbatim source line ranges; separator lines mark gaps.
// Do not edit by hand: see PROVENANCE.json and test_xxmi_conditional_contract.py.
		first = wline.find_first_not_of(L" \t");
		last = wline.find_last_not_of(L" \t");

		if (first == wline.npos)
			continue;

		wline = wline.substr(first, last - first + 1);
