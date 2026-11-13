// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
// Minimal authenticated excerpt of XXMI-Libs-Package v1.2.3 (commit 065dc746c21c71ef48bbc93cb6b90b3dcdf766e6),
// GPL-3.0-only, for the SRMI conditional-chain folding fail-closed regression test.
// Blocks are verbatim source line ranges; separator lines mark gaps.
// Do not edit by hand: see PROVENANCE.json and test_xxmi_conditional_fold.py.
// Which side of a batchable copy the batch owns:
// a bind batch drives the destination slot, a fetch batch reads the source.
// Everything in the optimiser that differs between the two is selected by this.
enum class BatchDirection {
	Bind,
	Fetch,
};
// --- verbatim source excerpt gap ---
// One branch of an if/elif/else chain folded into a ConditionalSlotCopyOperation:
// condition is NULL for the unconditional terminal branch,
// the else, or the "no branch taken" sentinel below.
// op is NULL when that branch makes no assignment at all:
// a missing else leaves the current binding, the same as unless_null.
struct ConditionalSlotBranch {
	CommandListExpression *condition;
	std::shared_ptr<ResourceCopyOperation> op;
};

// A chain of if/elif/else where every reachable branch targets the same slot,
// always a fixed one, folded by the optimiser into a single operation.
// It can then sit inside a ShaderResourceBindBatch/FetchBatch,
// instead of acting as a hard break.
//
// The conditions are evaluated at run time, and whichever branch matched runs.
// Its own dst/src are never used:
// the copy belongs to the branch, and the batch groups by BatchTarget().
class ConditionalSlotCopyOperation : public ResourceCopyOperation {
public:
	BatchDirection direction = BatchDirection::Bind;
	std::vector<ConditionalSlotBranch> branches;
	// The chain this was folded from, held for two reasons:
	// `branches` points into its CommandListExpressions,
	// and an operation left out of a batch goes back in as the chain itself:
	std::shared_ptr<CommandListCommand> source_if;

	void run(CommandListState*) override;
	void RunWithSource(CommandListState* state, ID3D11Resource* src_resource, ID3D11View* src_view) override;
	const ResourceCopyTarget& BatchTarget(BatchDirection direction) const override;

private:
	// The branch whose condition holds, or NULL when no branch is taken:
	ConditionalSlotBranch* MatchingBranch(CommandListState *state);
};

void merge_shader_resource_batches(CommandList *command_list);
