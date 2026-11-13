// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Minimal authenticated excerpt of XXMI-Libs-Package v1.2.3 (commit 065dc746c21c71ef48bbc93cb6b90b3dcdf766e6),
// GPL-3.0-only, for the SRMI conditional-flow regression test.
// Blocks are verbatim source line ranges; separator lines mark gaps.
// Do not edit by hand: see PROVENANCE.json and test_xxmi_conditional_contract.py.
inline wchar_t ascii_tolower(wchar_t c)
{
	return (c >= L'A' && c <= L'Z') ? c + (L'a' - L'A') : c;
}
// --- verbatim source excerpt gap ---
wstring get_namespaced_var_name_lower(const wstring& low_name, const wstring* ini_namespace)
{
	wstring ret = L"$\\" + *ini_namespace + L'\\';
	auto namespace_begin = ret.begin() + 2;  // Skip "$\\"
	std::transform(namespace_begin, namespace_begin + ini_namespace->size(), namespace_begin, ::towlower);
	ret.append(low_name, 1, wstring::npos);
	return ret;
}
// --- verbatim source excerpt gap ---
static bool ParseCommandListLine(const wchar_t *ini_section,
		const wchar_t *lhs, wstring *rhs, wstring *raw_line,
		CommandList *command_list,
		CommandList *explicit_command_list,
		CommandList *pre_command_list,
		CommandList *post_command_list,
		const wstring *ini_namespace)
{
	if (ParseCommandListVariableAssignment(ini_section, lhs, rhs, raw_line, command_list, pre_command_list, post_command_list, ini_namespace))
		return true;

	if (raw_line && !explicit_command_list &&
		ParseCommandListFlowControl(ini_section, raw_line, pre_command_list, post_command_list, ini_namespace))
		return true;

	if (ParseCommandListGeneralCommands(ini_section, lhs, rhs, explicit_command_list, pre_command_list, post_command_list, ini_namespace))
		return true;

	if (ParseCommandListIniParamOverride(ini_section, lhs, rhs, command_list, ini_namespace))
		return true;

	if (ParseCommandListResourceCopyTargetDirective(ini_section, lhs, rhs, command_list, ini_namespace))
		return true;

	return false;
}

static bool ParseCommandListLine(const wchar_t *ini_section,
		const wchar_t *lhs, const wchar_t *rhs, wstring *raw_line,
		CommandList *command_list,
		const wstring *ini_namespace)
{
	wstring srhs = wstring(rhs);

	return ParseCommandListLine(ini_section, lhs, &srhs, raw_line, command_list, command_list, NULL, NULL, ini_namespace);
}

// This tries to parse each line in a section in order as part of a command
// list. A list of keys that may be parsed elsewhere can be passed in so that
// it can warn about unrecognised keys and detect duplicate keys that aren't
// part of the command list.
static void ParseCommandList(const wchar_t *id,
		CommandList *pre_command_list, CommandList *post_command_list,
		wchar_t *whitelist[], bool register_command_lists=true)
{
	IniSectionVector *section = NULL;
	IniSectionVector::iterator entry;
	wstring *key, *val, *raw_line;
	const wchar_t *key_ptr;
	CommandList *command_list, *explicit_command_list;
	IniSectionSet whitelisted_keys;
	CommandListScope scope;
	int i;

	// Safety check to make sure we are keeping the command list section
	// list up to date:
	if (!IsCommandListSection(id)) {
		LogInfoW(L"BUG: ParseCommandList() called on a section not in the CommandListSections list: %s\n", id);
		DoubleBeepExit();
	}

	scope.emplace_front();

	LogDebug("Registering command list: %S\n", id);
	pre_command_list->ini_section = id;
	pre_command_list->post = false;
	pre_command_list->scope = &scope;
	if (register_command_lists)
		registered_command_lists.push_back(pre_command_list);
	if (post_command_list) {
		post_command_list->ini_section = id;
		post_command_list->post = true;
		post_command_list->scope = &scope;
		if (register_command_lists)
			registered_command_lists.push_back(post_command_list);
	}

	GetIniSection(&section, id);
	for (entry = section->begin(); entry < section->end(); entry++) {
		key = &entry->first;
		val = &entry->second;
		raw_line = &entry->raw_line;

		// Convert key + val to lower case since ini files are supposed
		// to be case insensitive:
		std::transform(key->begin(), key->end(), key->begin(), ::towlower);
		std::transform(val->begin(), val->end(), val->begin(), ::towlower);
		std::transform(raw_line->begin(), raw_line->end(), raw_line->begin(), ::towlower);

		// Skip any whitelisted entries that are parsed elsewhere.
		if (whitelist) {
			for (i = 0; whitelist[i]; i++) {
				if (!key->compare(whitelist[i]))
					break;
			}
			if (whitelist[i]) {
				// Entry is whitelisted and will be parsed
				// elsewhere. Sections with command lists are
				// allowed duplicate keys *except for these
				// whitelisted entries*, so check for
				// duplicates here:
				if (whitelisted_keys.count(key->c_str())) {
					IniWarningW(L"Duplicate non-command list key found: %ls\n - [%ls]\n", key->c_str(), id);
				}
				whitelisted_keys.insert(key->c_str());

				continue;
			}
		}

		command_list = pre_command_list;
		explicit_command_list = NULL;
		key_ptr = key->c_str();
		if (post_command_list) {
			if (!key->compare(0, 5, L"post ")) {
				key_ptr += 5;
				command_list = post_command_list;
				explicit_command_list = post_command_list;
			} else if (!key->compare(0, 4, L"pre ")) {
				key_ptr += 4;
				explicit_command_list = pre_command_list;
			}
		}

		if (ParseCommandListLine(id, key_ptr, val, raw_line, command_list, explicit_command_list, pre_command_list, post_command_list, &entry->ini_namespace)) {
			LogInfoW(L"  %ls\n", raw_line->c_str());
			continue;
		}

		// Unknown d3dx_user.ini entries warning is handled by ShowUnknownSettingsNotification.
		if (entry->ini_namespace == G->user_config && !G->user_config.empty())
			continue;

		IniWarningW(L"Unrecognised entry: %ls\n - [%ls] @ [%ls]\n", raw_line->c_str(), id, entry->ini_namespace.c_str());
	}

	// Don't need the scope objects once parsing is complete. If all
	// if/endifs were balanced correctly we should be back to the initial
	// scope, so warn if we aren't:


	if (std::distance(begin(scope), end(scope)) != 1) {
		IniWarningW(L"Scope unbalanced\n - [%ls]\n", id);
	}

	pre_command_list->scope = NULL;
	if (post_command_list)
		post_command_list->scope = NULL;
}
