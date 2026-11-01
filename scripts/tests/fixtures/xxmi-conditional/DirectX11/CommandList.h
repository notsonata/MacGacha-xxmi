// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Minimal authenticated excerpt of XXMI-Libs-Package v1.2.2 (commit a7847eae82aaac32175c9a7d199673d5c9323bcd),
// GPL-3.0-only, for the SRMI conditional-flow regression test.
// Blocks are verbatim source line ranges; separator lines mark gaps.
// Do not edit by hand: see PROVENANCE.json and test_xxmi_conditional_contract.py.
class CommandListCommand {
public:
	wstring ini_line;

	// For performance metrics:
	LARGE_INTEGER pre_time_spent;
	LARGE_INTEGER post_time_spent;
	unsigned pre_executions;
	unsigned post_executions;
	unsigned profiling_generation = 0;

	virtual ~CommandListCommand() {};

	virtual void run(CommandListState*) = 0;
	virtual bool optimise(HackerDevice *device) { return false; }
	virtual bool noop(bool post, bool ignore_cto_pre, bool ignore_cto_post) { return false; }
};

enum class VariableFlags {
	NONE            = 0,
	GLOBAL          = 0x00000001,
	PERSIST         = 0x00000002,
	LOCKED          = 0x00000004,
	INVALID         = (signed)0xffffffff,
};
SENSIBLE_ENUM(VariableFlags);
static EnumName_t<const wchar_t *, VariableFlags> VariableFlagNames[] = {
	{L"global",  VariableFlags::GLOBAL},
	{L"persist", VariableFlags::PERSIST},
	{L"locked",  VariableFlags::LOCKED},

	{NULL,       VariableFlags::INVALID} // End of list marker
};

class CommandListVariable {
public:
	wstring name;
	// TODO: Additional types, such as hash
	float fval;
	VariableFlags flags;

	CommandListVariable(wstring name, float fval, VariableFlags flags) :
		name(name), fval(fval), flags(flags)
	{}

	void CopyStateFrom(const CommandListVariable& src)
	{
		fval = src.fval;
		flags = src.flags;
	}
};

typedef std::unordered_map<std::wstring, class CommandListVariable> CommandListVariables;
extern CommandListVariables command_list_globals;
extern std::vector<CommandListVariable*> persistent_variables;
extern std::map<std::wstring, float> unknown_variables;

// The scope object is used to declare local variables in a command list. The
// multiple levels are to isolate variables declared inside if blocks from
// being accessed in a parent or sibling scope, while allowing variables
// declared in a parent scope to be used in an if block. This scope object is
// only used during command list parsing - once allocated the commands and
// operands referencing these variables will point directly to the variable
// objects to avoid slow lookups at runtime, and the scope object will be
// cleared to save memory (with some refactoring we could potentially even
// remove it from the CommandList class altogether).
typedef std::forward_list<std::unordered_map<std::wstring, CommandListVariable*>> CommandListScope;
// --- verbatim source excerpt gap ---
class CommandList {
public:
	// Using vector of pointers to allow mixed types, and shared_ptr to handle
	// destruction of each object:
	typedef std::vector<std::shared_ptr<CommandListCommand>> Commands;
	Commands commands;

	// For local/static variables. These are only used in the main pre
	// command list as the post command list and any sub command lists (if
	// blocks, etc) shares the same local variables and scope object as the
	// pre list. static_vars used to hold the variables in the pre command
	// list so they can be freed along with the command list, but at
	// runtime they are accessed directly by pointer. forward_list is used
	// because it doesn't invalidate pointers on insertion like vectors do.
	std::forward_list<CommandListVariable> static_vars;
	CommandListScope *scope;

	// For performance metrics:
	wstring ini_section;
	bool post;
	LARGE_INTEGER time_spent_inclusive;
	LARGE_INTEGER time_spent_exclusive;
	unsigned executions;
	unsigned profiling_generation = 0;

	bool runtime_populated = false;

	void clear();

	bool SetSourceCommandList(CommandList* source);
	CommandList* ResolveCommandList();
	bool CommandList::noop();

	CommandList() :
		post(false),
		scope(NULL)
	{}

private:
	CommandList* source_command_list = nullptr;
};

extern std::vector<CommandList*> registered_command_lists;
extern std::unordered_set<CommandList*> command_lists_profiling;
extern std::unordered_set<CommandListCommand*> command_lists_cmd_profiling;
void clear_command_list_profiling();
// --- verbatim source excerpt gap ---
class CommandListEvaluatable {
public:
	virtual ~CommandListEvaluatable() {}; // Because C++

	virtual float evaluate(CommandListState *state, HackerDevice *device=NULL) = 0;
	virtual bool static_evaluate(float *ret, HackerDevice *device=NULL, bool evaluate_variables=false) = 0;
	virtual bool optimise(HackerDevice *device, std::shared_ptr<CommandListEvaluatable> *replacement) = 0;
};
// --- verbatim source excerpt gap ---
class CommandListExpression {
public:
	std::shared_ptr<CommandListEvaluatable> evaluatable;

	bool parse(const wstring *expression, const wstring *ini_namespace, CommandListScope *scope);
	float evaluate(CommandListState *state, HackerDevice *device=NULL);
	bool static_evaluate(float *ret, HackerDevice *device=NULL, bool evaluate_variables=false);
	bool optimise(HackerDevice *device);
};
// --- verbatim source excerpt gap ---
class IfCommand : public CommandListCommand {
public:
	CommandListExpression expression;
	bool pre_finalised, post_finalised;
	bool has_nested_else_if;
	wstring section;

	bool static_evaluated = false;
	bool is_static = false;
	float static_val = 0.0f;

	// Commands cannot statically contain command lists, because the
	// command may be optimised out and the command list freed while we are
	// still in the middle of optimisations. These are dynamically
	// allocated, and also stored in a second data structure until
	// optimisations are complete
	std::shared_ptr<CommandList> true_commands_pre;
	std::shared_ptr<CommandList> true_commands_post;
	std::shared_ptr<CommandList> false_commands_pre;
	std::shared_ptr<CommandList> false_commands_post;

	IfCommand(const wchar_t *section);

	void run(CommandListState*) override;
	bool optimise(HackerDevice *device) override;
	bool noop(bool post, bool ignore_cto_pre, bool ignore_cto_post) override;
};

class ElseIfCommand : public IfCommand {
public:
	ElseIfCommand(const wchar_t *section) :
		IfCommand(section)
	{}
};

class CommandPlaceholder : public CommandListCommand {
public:
	void run(CommandListState*) override;
	bool noop(bool post, bool ignore_cto_pre, bool ignore_cto_post) override;
};
class ElsePlaceholder : public CommandPlaceholder {
};
