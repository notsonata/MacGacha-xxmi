// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Minimal authenticated excerpt of XXMI-Libs-Package v1.2.3 (commit 065dc746c21c71ef48bbc93cb6b90b3dcdf766e6),
// GPL-3.0-only, for the SRMI conditional-chain folding fail-closed regression test.
// Blocks are verbatim source line ranges; separator lines mark gaps.
// Do not edit by hand: see PROVENANCE.json and test_xxmi_conditional_fold.py.
void optimise_command_lists(HackerDevice *device)
{
	bool making_progress;
	bool ignore_cto_pre, ignore_cto_post;
	size_t i;
	CommandList::Commands::iterator new_end;
	DWORD start;

	LogInfo("Optimising command lists...\n");
	start = GetTickCount();

	for (CommandList *command_list : registered_command_lists) {
		for (i = 0; i < command_list->commands.size(); i++)
			command_list->commands[i]->optimise(device);
	}

	do {
		making_progress = false;
		ignore_cto_pre = true;
		ignore_cto_post = true;

		// If all TextureOverride sections have empty command lists of
		// either pre or post, we can treat checktextureoverride as a
		// noop. This is intended to catch the case where we only have
		// "pre" commands in the TextureOverride sections to optimise
		// out the implicit "post checktextureoverride" commands, as
		// these can add up if they are used on very common shaders
		// (e.g. in DOAXVV this can easily save 0.2fps on a 4GHz CPU,
		// more on a slower CPU since this command is used in the
		// shadow map shaders)
		//
		// FIXME: This should itself ignore any checktextureoverrides
		// inside these command lists
		for (auto &tolkv : G->mTextureOverrideMap) {
			for (TextureOverride &to : tolkv.second) {
				ignore_cto_pre = ignore_cto_pre && to.command_list.noop();
				ignore_cto_post = ignore_cto_post && to.post_command_list.noop();
			}
		}
		for (auto &tof : G->mFuzzyTextureOverrides) {
			ignore_cto_pre = ignore_cto_pre && tof->texture_override->command_list.noop();
			ignore_cto_post = ignore_cto_post && tof->texture_override->post_command_list.noop();
		}

		// Go through each registered command list and remove any
		// commands that are noops to eliminate the runtime overhead of
		// processing these
		for (CommandList *command_list : registered_command_lists) {
			for (i = 0; i < command_list->commands.size(); ) {
				if (command_list->commands[i]->noop(command_list->post, ignore_cto_pre, ignore_cto_post)) {
					LogInfo("Optimised out %s %S\n",
							command_list->post ? "post" : "pre",
							command_list->commands[i]->ini_line.c_str());
					command_list->commands.erase(command_list->commands.begin() + i);
					making_progress = true;
					continue;
				}
				i++;
			}
		}

		// TODO: Merge adjacent commands if possible, e.g. all the
		// commands in BuiltInCommandListUnbindAllRenderTargets would
		// be good candidates to merge into a single command. We could
		// add a special command for that particular case, but would be
		// nice if this sort of thing worked more generally.
	} while (making_progress);

	for (CommandList *command_list : registered_command_lists)
		merge_shader_resource_batches(command_list);

	Profiling::update_cto_warning(!ignore_cto_post);

	LogInfo("Command List Optimiser finished after %ums\n", GetTickCount() - start);
	registered_command_lists.clear();
	dynamically_allocated_command_lists.clear();
}
// --- verbatim source excerpt gap ---
// Optimiser support: merge runs of adjacent slot binds / fetches. Copy
// options don't matter: the operation still does its own copy / view
// creation, only the final XXSetShaderResources is deferred to the batch.

static bool is_batchable_bind(const ResourceCopyOperation *op)
{
	// Sources must not be pipeline slots, otherwise reading them all before
	// binding any would change the meaning of e.g. a slot swap:
	return op->dst.type == ResourceCopyTargetType::SHADER_RESOURCE
		&& op->dst.evaluation_mode == ResourceCopyTargetEvaluationMode::RESOURCE
		&& !op->dst.slot_expression
		&& (op->src.type == ResourceCopyTargetType::CUSTOM_RESOURCE || op->src.type == ResourceCopyTargetType::EMPTY)
		&& op->src.evaluation_mode == ResourceCopyTargetEvaluationMode::RESOURCE;
}

static bool is_batchable_fetch(const ResourceCopyOperation *op)
{
	return op->src.type == ResourceCopyTargetType::SHADER_RESOURCE
		&& op->src.evaluation_mode == ResourceCopyTargetEvaluationMode::RESOURCE
		&& !op->src.slot_expression
		&& op->dst.type == ResourceCopyTargetType::CUSTOM_RESOURCE
		&& op->dst.evaluation_mode == ResourceCopyTargetEvaluationMode::RESOURCE;
}

const ResourceCopyTarget& ResourceCopyOperation::BatchTarget(BatchDirection direction) const
{
	return direction == BatchDirection::Bind ? dst : src;
}

static bool is_batchable(const ResourceCopyOperation *op, BatchDirection direction)
{
	return direction == BatchDirection::Bind ? is_batchable_bind(op) : is_batchable_fetch(op);
}

// Every branch of a chain has to drive the slot the first branch fixed.
static bool same_batch_target(const ResourceCopyOperation *op, const ResourceCopyOperation *first,
	BatchDirection direction)
{
	const ResourceCopyTarget &target = op->BatchTarget(direction);
	const ResourceCopyTarget &fixed = first->BatchTarget(direction);

	return target.shader_type == fixed.shader_type && target.slot == fixed.slot;
}

// Every branch was checked to drive the same slot,
// so the first one speaks for the chain.
const ResourceCopyTarget& ConditionalSlotCopyOperation::BatchTarget(BatchDirection direction) const
{
	return branches[0].op->BatchTarget(direction);
}

ConditionalSlotBranch* ConditionalSlotCopyOperation::MatchingBranch(CommandListState *state)
{
	for (auto &branch : branches) {
		if (!branch.condition || branch.condition->evaluate(state))
			return branch.op ? &branch : NULL; // NULL op: no branch taken
	}
	return NULL;
}

void ConditionalSlotCopyOperation::run(CommandListState *state)
{
	ConditionalSlotBranch *branch = MatchingBranch(state);
	if (!branch) {
		COMMAND_LIST_LOG(state, "%S: no branch taken, keeping the current binding\n", ini_line.c_str());
		return;
	}

	// Hand our own deferred binding to whichever branch matched,
	// and let its operation run with its own dst/src/options,
	// exactly as if it had run standalone:
	branch->op->deferred = deferred;
	branch->op->run(state);
	branch->op->deferred = NULL;
}

// Fetch direction:
// ShaderResourceFetchBatch already read the slot,
// and hands its contents to whichever branch matched.
void ConditionalSlotCopyOperation::RunWithSource(CommandListState *state, ID3D11Resource *src_resource, ID3D11View *src_view)
{
	ConditionalSlotBranch *branch = MatchingBranch(state);
	if (branch)
		branch->op->RunWithSource(state, src_resource, src_view);
	else
		COMMAND_LIST_LOG(state, "%S: no branch taken\n", ini_line.c_str());
}

// Whether an expression reads pipeline state (ps-t0, ps-t0->Width, ...).
// Inside a batch the binds of the run are deferred to its end,
// so such a condition would see the bindings from before the run,
// rather than the ones the lines above it just made.
static bool expression_reads_pipeline(CommandListEvaluatable *node)
{
	if (auto operand = dynamic_cast<CommandListOperand *>(node))
		return operand->type == ParamOverrideType::TEXTURE;
	if (auto op = dynamic_cast<CommandListOperator *>(node))
		return (op->lhs && expression_reads_pipeline(op->lhs.get()))
			|| (op->rhs && expression_reads_pipeline(op->rhs.get()));
	return false;
}

// An if/elif/else chain is registered in both of its section's lists,
// and the optimiser works on one list at a time.
// Only the half that belongs to the list being optimised may be folded into it.
// Otherwise a chain whose assignments are all "pre" would be folded again,
// into the post list, and applied a second time after the draw call.
enum class CommandListPhase {
	Pre,
	Post,
};

static const CommandList::Commands& branch_commands(const std::shared_ptr<CommandList> &pre,
	const std::shared_ptr<CommandList> &post, CommandListPhase phase)
{
	return (phase == CommandListPhase::Pre ? pre : post)->commands;
}

// The one batchable operation a branch runs in this phase,
// or nullptr when the branch is not shaped for folding:
// it runs nothing, or more than one command,
// or a command that is not a batchable copy in this direction.
static std::shared_ptr<ResourceCopyOperation> extract_batchable_branch(const CommandList::Commands &commands,
	BatchDirection direction)
{
	if (commands.size() != 1)
		return nullptr;

	auto op = std::dynamic_pointer_cast<ResourceCopyOperation>(commands[0]);
	if (!op || !is_batchable(op.get(), direction))
		return nullptr;

	return op;
}

// A bind batch writes every slot in its range,
// so a chain that may leave its slot alone has to ask for the current binding,
// exactly as a plain unless_null line does.
// That happens when no branch is taken,
// or when an unless_null branch's source turns out to be null.
static bool chain_may_keep_binding(const std::vector<ConditionalSlotBranch> &branches)
{
	for (auto &branch : branches) {
		if (!branch.op || (branch.op->options & ResourceCopyOptions::UNLESS_NULL))
			return true;
	}

	return false;
}

// Appends one entry per branch of a simple if/elif/else chain.
// Fails unless every reachable branch runs exactly one batchable operation,
// on the slot the first branch fixed.
// The final empty else is allowed, and means "leave the current binding",
// which is the same thing unless_null already does for a batch.
static bool collect_conditional_chain(IfCommand *if_cmd, BatchDirection direction, CommandListPhase phase,
	std::vector<ConditionalSlotBranch> &out)
{
	if (expression_reads_pipeline(if_cmd->expression.evaluatable.get()))
		return false;

	auto op = extract_batchable_branch(branch_commands(if_cmd->true_commands_pre,
			if_cmd->true_commands_post, phase), direction);
	if (!op)
		return false;

	// out[0] always carries an operation,
	// since the empty else below is only appended after a real branch,
	// so it is the one that fixed the slot:
	if (!out.empty() && !same_batch_target(op.get(), out[0].op.get(), direction))
		return false;

	out.push_back({ &if_cmd->expression, op });

	const CommandList::Commands &else_commands = branch_commands(if_cmd->false_commands_pre,
			if_cmd->false_commands_post, phase);
	if (else_commands.empty()) {
		out.push_back({ nullptr, nullptr });
		return true;
	}

	if (if_cmd->has_nested_else_if) {
		auto nested_if = else_commands.size() == 1
			? std::dynamic_pointer_cast<IfCommand>(else_commands[0]) : nullptr;

		return nested_if && collect_conditional_chain(nested_if.get(), direction, phase, out);
	}

	auto else_op = extract_batchable_branch(else_commands, direction);
	if (!else_op || !same_batch_target(else_op.get(), out[0].op.get(), direction))
		return false;

	out.push_back({ nullptr, else_op });
	return true;
}

// Folds an if/elif/else chain whose every reachable branch drives one slot,
// into a single operation that can take its place inside a batch.
// Returns nullptr when the chain is not shaped for that.
static std::shared_ptr<ResourceCopyOperation> fold_conditional_slot_chain(const std::shared_ptr<IfCommand> &if_cmd,
	BatchDirection direction, CommandListPhase phase)
{
	auto folded = std::make_shared<ConditionalSlotCopyOperation>();

	if (!collect_conditional_chain(if_cmd.get(), direction, phase, folded->branches))
		return nullptr;

	folded->direction = direction;
	if (chain_may_keep_binding(folded->branches))
		folded->options |= ResourceCopyOptions::UNLESS_NULL;
	folded->ini_line = if_cmd->ini_line;
	folded->source_if = if_cmd;

	return folded;
}

// An operation that ends up outside any batch goes back into the list as it was.
// For a folded if/elif/else chain that is the original IfCommand,
// so it runs and logs exactly as before.
static std::shared_ptr<CommandListCommand> unbatched(const std::shared_ptr<ResourceCopyOperation> &op)
{
	if (auto folded = std::dynamic_pointer_cast<ConditionalSlotCopyOperation>(op))
		return folded->source_if;
	return op;
}

// Wraps the operations of a run that fall within [first, last] into a single
// bind / fetch batch and appends it to out. A range holding a single
// operation is not worth a batch, that operation is appended as is.
static void emit_slot_batch(const std::vector<std::shared_ptr<ResourceCopyOperation>> &run, BatchDirection direction,
	unsigned first, unsigned last, bool prefetch_current_bindings, CommandList::Commands &out)
{
	std::shared_ptr<ShaderResourceBatch> batch;
	if (direction == BatchDirection::Bind)
		batch = std::make_shared<ShaderResourceBindBatch>();
	else
		batch = std::make_shared<ShaderResourceFetchBatch>();

	// Operations keep their ini order within the batch, so a slot assigned
	// twice takes the last value just like it would without batching:
	for (auto &op : run) {
		unsigned slot = op->BatchTarget(direction).slot;
		if (slot >= first && slot <= last)
			batch->operations.push_back(op);
	}

	if (batch->operations.size() < 2) {
		out.push_back(unbatched(batch->operations[0]));
		return;
	}

	batch->shader_type = run[0]->BatchTarget(direction).shader_type;
	batch->first_slot = first;
	batch->count = last - first + 1;
	batch->prefetch_current_bindings = prefetch_current_bindings;
	// Shown in the frame analysis log in place of the individual lines:
	batch->ini_line = batch->operations[0]->ini_line + L" ... +" + std::to_wstring(batch->operations.size() - 1);
	out.push_back(batch);
}

// Splits a run of same-stage, same-direction operations into batches and
// appends them to out.
//
// A single XXSetShaderResources call always writes every slot in its range,
// so a batch normally only covers slots the run actually assigns: the run is
// split wherever the (sorted, unique) slot numbers have a gap, and each
// contiguous range becomes its own batch.
//
// unless_null changes that for binds. A slot whose source turned out to be
// null has to keep its current view, and the only way to know that view is
// to XXGetShaderResources the range up front (prefetch_current_bindings).
// Since the current bindings are read anyway, gaps cost nothing extra: the
// gap slots are simply written back with the view they already had, and the
// whole run becomes one batch spanning from the lowest to the highest slot.
static void emit_slot_batches(const std::vector<std::shared_ptr<ResourceCopyOperation>> &run,
	BatchDirection direction, CommandList::Commands &out)
{
	bool prefetch_current_bindings = false;
	std::vector<unsigned> slots;

	for (auto &op : run) {
		slots.push_back(op->BatchTarget(direction).slot);
		if (direction == BatchDirection::Bind && (op->options & ResourceCopyOptions::UNLESS_NULL))
			prefetch_current_bindings = true;
	}
	std::sort(slots.begin(), slots.end());
	slots.erase(std::unique(slots.begin(), slots.end()), slots.end());

	if (prefetch_current_bindings) {
		emit_slot_batch(run, direction, slots.front(), slots.back(), true, out);
		return;
	}

	unsigned first = slots[0];
	for (size_t i = 1; i < slots.size(); i++) {
		if (slots[i] != slots[i - 1] + 1) {
			emit_slot_batch(run, direction, first, slots[i - 1], false, out);
			first = slots[i];
		}
	}
	emit_slot_batch(run, direction, first, slots.back(), false, out);
}

// Optimiser pass: walks the command list once and replaces every run of two
// or more adjacent batchable operations with bind / fetch batches. A run is
// a maximal sequence of consecutive commands that are all batchable binds
// or all batchable fetches for the same shader stage; any other command
// (including a batchable one for another stage or direction) ends it. The
// order of commands is preserved, batches take the place of their first
// operation.
void merge_shader_resource_batches(CommandList *command_list)
{
	CommandList::Commands out;
	std::vector<std::shared_ptr<ResourceCopyOperation>> run;
	BatchDirection run_direction = BatchDirection::Bind;
	wchar_t run_stage = L'\0';
	CommandListPhase phase = command_list->post ? CommandListPhase::Post : CommandListPhase::Pre;

	// Ends the current run: a lone operation goes through unchanged, two or
	// more are handed to emit_slot_batches.
	auto flush = [&]() {
		if (run.size() == 1)
			out.push_back(unbatched(run[0]));
		else if (run.size() > 1)
			emit_slot_batches(run, run_direction, out);
		run.clear();
	};

	for (auto &command : command_list->commands) {
		auto op = std::dynamic_pointer_cast<ResourceCopyOperation>(command);
		BatchDirection direction = BatchDirection::Bind;

		if (op) {
			if (is_batchable_fetch(op.get()))
				direction = BatchDirection::Fetch;
			else if (!is_batchable_bind(op.get()))
				op = nullptr;
		} else if (auto if_cmd = std::dynamic_pointer_cast<IfCommand>(command)) {
			// A chain that targets one fixed slot is folded in,
			// rather than acting as a hard break:
			for (BatchDirection candidate : { BatchDirection::Bind, BatchDirection::Fetch }) {
				op = fold_conditional_slot_chain(if_cmd, candidate, phase);
				if (op) {
					direction = candidate;
					break;
				}
			}
		}

		if (!op) {
			flush();
			out.push_back(command);
			continue;
		}

		wchar_t stage = op->BatchTarget(direction).shader_type;
		if (!run.empty() && (direction != run_direction || stage != run_stage))
			flush();

		run_direction = direction;
		run_stage = stage;
		run.push_back(op);
	}
	flush();

	// Every batch replaces at least two commands, so a shorter list means
	// something was merged:
	if (out.size() != command_list->commands.size()) {
		LogInfo("Merged %Iu slot operations into batches in [%S]\n", command_list->commands.size() - out.size(), command_list->ini_section.c_str());
		command_list->commands = std::move(out);
	}
}
