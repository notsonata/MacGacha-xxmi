// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Minimal authenticated excerpt of XXMI-Libs-Package v1.2.2 (commit a7847eae82aaac32175c9a7d199673d5c9323bcd),
// GPL-3.0-only, for the SRMI conditional-flow regression test.
// Blocks are verbatim source line ranges; separator lines mark gaps.
// Do not edit by hand: see PROVENANCE.json and test_xxmi_conditional_contract.py.
static void _RunCommandList(CommandList *command_list, CommandListState *state, bool recursive=true)
{
	CommandList::Commands::iterator i;
	command_list_profiling_state profiling_state;

	command_list = command_list->ResolveCommandList();
	
	if (state->recursion > MAX_COMMAND_LIST_RECURSION) {
		LogOverlayW(LOG_WARNING, L"Command list recursion limit exceeded! Circular reference?\n - [%ls]\n", command_list->ini_section.c_str());
		return;
	}

	if (command_list->commands.empty())
		return;

	if (recursive) {
		COMMAND_LIST_LOG(state, "%s {\n", state->post ? "post" : "pre");
		state->recursion++;
	}

	profile_command_list_start(command_list, state, &profiling_state);

	for (i = command_list->commands.begin(); i < command_list->commands.end() && !state->aborted; i++) {
		profile_command_list_cmd_start(i->get(), &profiling_state);
		(*i)->run(state);
		profile_command_list_cmd_end(i->get(), state, &profiling_state);
	}

	profile_command_list_end(command_list, state, &profiling_state);

	if (recursive) {
		state->recursion--;
		COMMAND_LIST_LOG(state, "}\n");
	}
}

// --- verbatim source excerpt gap ---
static bool AddCommandToList(CommandListCommand *command,
		CommandList *explicit_command_list,
		CommandList *sensible_command_list,
		CommandList *pre_command_list,
		CommandList *post_command_list,
		const wchar_t *section,
		const wchar_t *key, wstring *val)
{
	if (section && key) {
		command->ini_line = L"[" + wstring(section) + L"] " + wstring(key);
		if (val)
			command->ini_line += L" = " + *val;
	}

	if (explicit_command_list) {
		// User explicitly specified "pre" or "post", so only add the
		// command to that list
		explicit_command_list->commands.push_back(std::shared_ptr<CommandListCommand>(command));
	} else if (sensible_command_list) {
		// User did not specify which command list to add it to, but
		// the command they specified has a sensible default, so add it
		// to that list:
		sensible_command_list->commands.push_back(std::shared_ptr<CommandListCommand>(command));
	} else {
		// The command's default is to add it to both lists (e.g. the
		// checktextureoverride directive will call command lists in
		// another ini section with both pre and post lists, so the
		// principal of least unexpected behaviour says we add it to
		// both so that both those command lists will be called)
		//
		// Using a std::shared_ptr here to handle adding the same
		// pointer to two lists and have it garbage collected only once
		// both are destroyed:
		std::shared_ptr<CommandListCommand> p(command);
		pre_command_list->commands.push_back(p);
		if (post_command_list)
			post_command_list->commands.push_back(p);
	}

	return true;
}
// --- verbatim source excerpt gap ---
int find_local_variable(const wstring& name, CommandListScope* scope, CommandListVariable** var)
{
	CommandListScope::iterator it;

	if (!scope)
		return false;

	if (name.length() < 2 || name[0] != L'$')
		return false;

	for (it = scope->begin(); it != scope->end(); it++) {
		auto match = it->find(name);
		if (match != it->end()) {
			*var = match->second;
			return true;
		}
	}

	return false;
}

// --- verbatim source excerpt gap ---
void CommandList::clear()
{
	commands.clear();
	static_vars.clear();
}
// --- verbatim source excerpt gap ---
CommandList* CommandList::ResolveCommandList()
{
	return source_command_list ? source_command_list->ResolveCommandList() : this;
}

bool CommandList::noop()
{
	CommandList* resolved = ResolveCommandList();

	if (resolved->runtime_populated)
		return false;

	return resolved->commands.empty();
}
// --- verbatim source excerpt gap ---
enum class OptionalChars : uint8_t
{
	NONE   = 0b0000,
	HYPHEN = 0b0001,
	PERIOD = 0b0010,
	ALL    = 0b1111,
};
SENSIBLE_ENUM(OptionalChars);

static inline bool is_identifier_char(wchar_t c, OptionalChars identifier_flags)
{
	if ((c >= L'a' && c <= L'z') || (c >= L'0' && c <= L'9') || c == L'_')
		return true;

	if ((identifier_flags & OptionalChars::HYPHEN) && c == L'-')
		return true;

	if ((identifier_flags & OptionalChars::PERIOD) && c == L'.')
		return true;

	return false;
}

static inline bool is_operator_char(wchar_t c)
{
	switch (c)
	{
	case L'=':
	case L'&':
	case L'|':
	case L'+':
	case L'-':
	case L'/':
	case L'*':
	case L'>':
	case L'<':
	case L'%':
	case L'!':
	case L'^':
	case L'~':
	case L'(':
	case L')':
	case L'[':
	case L']':
		return true;

	default:
		return false;
	}
}

static size_t FindIdentifierTokenEnd(const std::wstring& str, const size_t start = 0, OptionalChars identifier_flags = OptionalChars::NONE)
{
	for (size_t i = start; i < str.size(); ++i)
	{
		wchar_t c = str[i];

		// Test for valid identifier char.
		if (!is_identifier_char(c, identifier_flags))
			return i;
	}

	return str.size();
}

enum class NamespaceState : uint8_t
{
	Waiting,            // No namespace prefix encountered yet.
	ParsingParent,      // Inside the first namespace segment (between the first and second '\').
	ParsingChild,       // Inside nested namespace path segments after the parent segment.
	ParsingIdentifier,  // Final segment; validation is delegated to the caller.
};

class NamespaceScanner
{
public:
	bool Consume(wchar_t c, const std::wstring& str, size_t pos)
    {
		switch (state_)
		{
		case NamespaceState::Waiting:
			if (c == L'\\')
			{
				state_ = NamespaceState::ParsingParent;
				return true;
			}
			return false;

		case NamespaceState::ParsingParent:
			if (c == L'\\')
			{
				state_ = NamespaceState::ParsingChild;
				return true;
			}

			// The parent namespace segment may contain arbitrary characters.
			return true;

		case NamespaceState::ParsingChild:
			// Allow path-like namespaces (e.g. \path\to\mod.ini\var_name).
			if (c != L'\\')
			{
				// Nested namespace path segments allow identifier characters plus periods.
				// Hyphens are excluded because they may be interpreted as the minus operator.
				return is_identifier_char(c, OptionalChars(OptionalChars::PERIOD));
			}

			// A separator may either start another namespace segment or precede the final identifier segment.
			// Perform only a broad boundary check here; the caller performs the final syntax validation.
			if (IsFinalSegmentCandidate(str, pos + 1))
			{
				state_ = NamespaceState::ParsingIdentifier;
				return true;
			}

			// Another nested path segment follows.
			return true;

		case NamespaceState::ParsingIdentifier:
			// The remaining characters belong to the final identifier and are validated by the caller's identifier scanner.
			return false;
		}

		return false;
	}

private:
	static bool IsFinalSegmentCandidate(const std::wstring& str, size_t start)
	{
		if (start >= str.size())
			return false;

		for (size_t i = start; i < str.size(); ++i)
		{
			wchar_t c = str[i];

			if (c == L'\\')
				return false;

			// Broad token-boundary check only. Actual syntax validation is performed later by the dedicated parser.
			if ((is_operator_char(c) && c != L'-') || iswspace(c))
				return false;
		}

		return true;
	}

private:
	NamespaceState state_ = NamespaceState::Waiting;
};

static size_t FindVariableTokenEnd(const std::wstring& str, size_t start = 0)
{
	// Scans a variable token and returns the end position after performing minimal syntax validation:
	// 1. Ensures identifier characters match `[a-z_0-9]+`.
	// 2. Ensures an optional namespace is properly closed while allowing arbitrary characters in the parent namespace segment.
	NamespaceScanner namespace_scanner;

	for (size_t i = start; i < str.size(); ++i)
	{
		wchar_t c = str[i];

		// Consume an optional leading namespace (e.g. "\namespace\" or "\path\like\namespace\").
		if (namespace_scanner.Consume(c, str, i))
			continue;

		// The remaining characters must be valid identifier characters.
		if (!is_identifier_char(c, OptionalChars::NONE))
			return i;
	}

	return str.size();
}
// --- verbatim source excerpt gap ---
bool parse_command_list_var_name(const wstring &name, const wstring *ini_namespace, CommandListVariable **target)
{
	CommandListVariables::iterator var = command_list_globals.end();

	if (name.length() < 2 || name[0] != L'$')
		return false;

	// We need value in lower case so our keys will be consistent in the
	// unordered_map. ParseCommandList will have already done this, but the
	// Key/Preset parsing code will not have, and rather than require it to
	// we do it here:
	wstring low_name(name);

	for (wchar_t& c : low_name)
		c = ascii_tolower(c);

	if (!ini_namespace->empty())
		var = command_list_globals.find(get_namespaced_var_name_lower(low_name, ini_namespace));

	if (var == command_list_globals.end())
		var = command_list_globals.find(low_name);

	if (var == command_list_globals.end())
		return false;

	*target = &var->second;
	return true;
}
// --- verbatim source excerpt gap ---
static bool ParseIfCommand(const wchar_t *section, const wstring *line,
		CommandList *pre_command_list, CommandList *post_command_list,
		const wstring *ini_namespace)
{
	IfCommand *operation = new IfCommand(section);
	wstring expression = line->substr(line->find_first_not_of(L" \t", 3));

	if (!operation->expression.parse(&expression, ini_namespace, pre_command_list->scope))
		goto bail;

	// New scope level to isolate local variables:
	pre_command_list->scope->emplace_front();

	return AddCommandToList(operation, NULL, NULL, pre_command_list, post_command_list, section, line->c_str(), NULL);
bail:
	delete operation;
	return false;
}

static bool ParseElseIfCommand(const wchar_t *section, const wstring *line, int prefix,
		CommandList *pre_command_list, CommandList *post_command_list,
		const wstring *ini_namespace)
{
	ElseIfCommand *operation = new ElseIfCommand(section);
	wstring expression = line->substr(line->find_first_not_of(L" \t", prefix));

	if (!operation->expression.parse(&expression, ini_namespace, pre_command_list->scope))
		goto bail;

	// Clear deepest scope level to isolate local variables:
	pre_command_list->scope->front().clear();

	// "else if" is implemented by nesting another if/endif inside the
	// parent if command's else clause. We add both an ElsePlaceholder and
	// an ElseIfCommand here, and will fix up the "endif" balance later.
	AddCommandToList(new ElsePlaceholder(), NULL, NULL, pre_command_list, post_command_list, section, line->c_str(), NULL);
	return AddCommandToList(operation, NULL, NULL, pre_command_list, post_command_list, section, line->c_str(), NULL);
bail:
	delete operation;
	return false;
}

static bool ParseElseCommand(const wchar_t *section,
		CommandList *pre_command_list, CommandList *post_command_list, const wstring* ini_namespace)
{
	// Clear deepest scope level to isolate local variables:
	pre_command_list->scope->front().clear();

	return AddCommandToList(new ElsePlaceholder(), NULL, NULL, pre_command_list, post_command_list, section, L"else", NULL);
}

static bool _ParseEndIfCommand(const wchar_t *section,
		CommandList *command_list, const wstring* ini_namespace, bool post, bool has_nested_else_if = false)
{
	CommandList::Commands::reverse_iterator rit;
	IfCommand *if_command;
	ElseIfCommand *else_if_command;
	ElsePlaceholder *else_command = NULL;
	CommandList::Commands::iterator else_pos = command_list->commands.end();

	for (rit = command_list->commands.rbegin(); rit != command_list->commands.rend(); rit++) {
		else_command = dynamic_cast<ElsePlaceholder*>(rit->get());
		if (else_command) {
			// C++ gotcha: reverse_iterator::base() points to the *next* element
			else_pos = rit.base() - 1;
		}

		if_command = dynamic_cast<IfCommand*>(rit->get());
		if (if_command) {
			// "else if" is treated as embedding another "if" block
			// in the else clause of the first "if" command. The
			// ElsePlaceholder was already inserted when the
			// ElseIfCommand was parsed, and this ElseIfCommand acts
			// as the nested IfCommand so the below code works as
			// is, but to balance the endifs we will need to repeat
			// this function until we find the original IfCommand:
			else_if_command = dynamic_cast<ElseIfCommand*>(rit->get());

			// Transfer the commands since the if command until the
			// endif into the if command's true/false lists
			if (post && !if_command->post_finalised) {
				// C++ gotcha: reverse_iterator::base() points to the *next* element
				if_command->true_commands_post->commands.assign(rit.base(), else_pos);
				if_command->true_commands_post->ini_section = if_command->ini_line;
				if (else_pos != command_list->commands.end()) {
					// Discard the else placeholder command:
					if_command->false_commands_post->commands.assign(else_pos + 1, command_list->commands.end());
					if_command->false_commands_post->ini_section = if_command->ini_line + L" <else>";
				}
				command_list->commands.erase(rit.base(), command_list->commands.end());
				if_command->post_finalised = true;
				if_command->has_nested_else_if = has_nested_else_if;
				if (else_if_command)
					return _ParseEndIfCommand(section, command_list, ini_namespace, post, true);
				return true;
			} else if (!post && !if_command->pre_finalised) {
				// C++ gotcha: reverse_iterator::base() points to the *next* element
				if_command->true_commands_pre->commands.assign(rit.base(), else_pos);
				if_command->true_commands_pre->ini_section = if_command->ini_line;
				if (else_pos != command_list->commands.end()) {
					// Discard the else placeholder command:
					if_command->false_commands_pre->commands.assign(else_pos + 1, command_list->commands.end());
					if_command->false_commands_pre->ini_section = if_command->ini_line + L" <else>";
				}
				command_list->commands.erase(rit.base(), command_list->commands.end());
				if_command->pre_finalised = true;
				if_command->has_nested_else_if = has_nested_else_if;
				if (else_if_command)
					return _ParseEndIfCommand(section, command_list, ini_namespace, post, true);
				return true;
			}
		}
	}
	LogOverlayW(LOG_WARNING, L"Statement \"endif\" missing \"if\"\n - [%ls] @ [%ls]\n", section, ini_namespace);
	return false;
}

static bool ParseEndIfCommand(const wchar_t *section,
		CommandList *pre_command_list, CommandList *post_command_list, const wstring* ini_namespace)
{
	bool ret;

	ret = _ParseEndIfCommand(section, pre_command_list, ini_namespace, false);
	if (post_command_list)
	    ret = ret && _ParseEndIfCommand(section, post_command_list, ini_namespace, true);

	if (ret)
		pre_command_list->scope->pop_front();

	return ret;
}

bool ParseCommandListFlowControl(const wchar_t *section, const wstring *line,
		CommandList *pre_command_list, CommandList *post_command_list,
		const wstring *ini_namespace)
{
	if (!wcsncmp(line->c_str(), L"if ", 3))
		return ParseIfCommand(section, line, pre_command_list, post_command_list, ini_namespace);
	if (!wcsncmp(line->c_str(), L"elif ", 5))
		return ParseElseIfCommand(section, line, 5, pre_command_list, post_command_list, ini_namespace);
	if (!wcsncmp(line->c_str(), L"else if ", 8))
		return ParseElseIfCommand(section, line, 8, pre_command_list, post_command_list, ini_namespace);
	if (!wcscmp(line->c_str(), L"else"))
		return ParseElseCommand(section, pre_command_list, post_command_list, ini_namespace);
	if (!wcscmp(line->c_str(), L"endif"))
		return ParseEndIfCommand(section, pre_command_list, post_command_list, ini_namespace);

	return false;
}

IfCommand::IfCommand(const wchar_t *section) :
	pre_finalised(false),
	post_finalised(false),
	has_nested_else_if(false),
	section(section)
{
	true_commands_pre = std::make_shared<CommandList>();
	true_commands_post = std::make_shared<CommandList>();
	false_commands_pre = std::make_shared<CommandList>();
	false_commands_post = std::make_shared<CommandList>();
	true_commands_post->post = true;
	false_commands_post->post = true;

	// Placeholder names to be replaced by endif processing - we should
	// never see these, but in case they do show up somewhere these will
	// provide a clue as to what they are:
	true_commands_pre->ini_section = L"if placeholder";
	true_commands_post->ini_section = L"if placeholder";
	false_commands_pre->ini_section = L"else placeholder";
	false_commands_post->ini_section = L"else placeholder";

	// Place the dynamically allocated command lists in this data structure
	// to ensure they stay alive until after the optimisation stage, even
	// if the IfCommand is freed, e.g. by being optimised out:
	dynamically_allocated_command_lists.push_back(true_commands_pre);
	dynamically_allocated_command_lists.push_back(true_commands_post);
	dynamically_allocated_command_lists.push_back(false_commands_pre);
	dynamically_allocated_command_lists.push_back(false_commands_post);

	// And register these command lists for later optimisation:
	registered_command_lists.push_back(true_commands_pre.get());
	registered_command_lists.push_back(true_commands_post.get());
	registered_command_lists.push_back(false_commands_pre.get());
	registered_command_lists.push_back(false_commands_post.get());
}

void IfCommand::run(CommandListState *state)
{
	if (expression.evaluate(state)) {
		COMMAND_LIST_LOG(state, "%S: true {\n", ini_line.c_str());
		state->extra_indent++;
		if (state->post)
			_RunCommandList(true_commands_post.get(), state, false);
		else
			_RunCommandList(true_commands_pre.get(), state, false);
		state->extra_indent--;
		COMMAND_LIST_LOG(state, "} endif\n");
	} else {
		COMMAND_LIST_LOG(state, "%S: false\n", ini_line.c_str());
		if (!has_nested_else_if) {
			COMMAND_LIST_LOG(state, "[%S] else {\n", section.c_str());
			state->extra_indent++;
		}
		if (state->post)
			_RunCommandList(false_commands_post.get(), state, false);
		else
			_RunCommandList(false_commands_pre.get(), state, false);
		if (!has_nested_else_if) {
			state->extra_indent--;
			COMMAND_LIST_LOG(state, "} endif\n");
		}
	}
}

bool IfCommand::optimise(HackerDevice *device)
{
	return expression.optimise(device);
}

bool IfCommand::noop(bool post, bool ignore_cto_pre, bool ignore_cto_post)
{
	if ((post && !post_finalised) || (!post && !pre_finalised)) {
		LogOverlayW(LOG_WARNING, L"Statement \"if\" missing \"endif\":\n - \"%ls\"\n", ini_line.c_str());
		return true;
	}

	if (!static_evaluated)
	{
		is_static = expression.static_evaluate(&static_val);
		static_evaluated = true;
	}

	if (is_static) {
		if (static_val) {
			false_commands_pre->clear();
			false_commands_post->clear();
		}
		else {
			true_commands_pre->clear();
			true_commands_post->clear();
		}
	}

	if (post)
		return true_commands_post->noop() && false_commands_post->noop();

	return true_commands_pre->noop() && false_commands_pre->noop();
}

void CommandPlaceholder::run(CommandListState*)
{
	LogOverlay(LOG_DIRE, "BUG: Placeholder command executed: %S\n", ini_line.c_str());
}

bool CommandPlaceholder::noop(bool post, bool ignore_cto_pre, bool ignore_cto_post)
{
	LogOverlayW(LOG_WARNING, L"Command not terminated\n - [%ls]\n", ini_line.c_str());
	return true;
}
