defmodule Handbean.Memory.PromptPolicy do
  @moduledoc """
  Generates a system prompt section describing memory tool usage policy.

  Takes a `Handbean.Memory.Policy` struct and produces policy-aware prompt text
  that can be injected into the agent's system prompt.

  Profiles:
    - `:balanced` (default) — full workflow with all seven tools and security guidance
    - `:strict`   — emphasizes security constraints and forbids auto-saving sensitive info
    - `:minimal`  — brief recall/learn rules only
  """

  alias Handbean.Memory.Policy

  @doc """
  Generates a memory policy prompt section for the given policy.

  ## Examples

      iex> policy = %Policy{profile: :balanced}
      iex> prompt = PromptPolicy.generate(policy)
      iex> prompt =~ "mem_recall" and prompt =~ "mem_learn"
      true

      iex> policy = %Policy{profile: :strict}
      iex> prompt = PromptPolicy.generate(policy)
      iex> prompt =~ "never"
      true
  """
  @spec generate(Policy.t()) :: String.t()
  def generate(%Policy{profile: :balanced}), do: balanced_prompt()
  def generate(%Policy{profile: :strict}), do: strict_prompt()
  def generate(%Policy{profile: :minimal}), do: minimal_prompt()

  # Fallback: invalid profile — raise with clear message (contract violation)
  def generate(%Policy{profile: other}) do
    raise ArgumentError,
          "Unknown memory policy profile: #{inspect(other)}. " <>
            "Valid profiles: :minimal, :balanced, :strict"
  end

  # ── Balanced profile ──────────────────────────────────────────────────

  defp balanced_prompt do
    """
    ## Memory

    You have access to memory tools: mem_recall, mem_learn, mem_reinforce,
    mem_associate, mem_update, mem_forget, and mem_reflect. Use them as a deterministic
    workflow, not an optional hint.

    ### When to recall
    - Before starting a task, call mem_recall to check if prior knowledge exists.
    - When you don't know how to do something and prior knowledge may help,
      recall first before broad exploration.

    ### When to learn
    - When you learn a durable fact, pattern, preference, rule, or constraint,
      call mem_learn. Memory starts as short-term (24h decay) unless reinforced.
    - Store non-obvious, durable knowledge that would save future reasoning.
    - Do not store generic summaries or facts obvious from a quick file read.

    ### When to reinforce
    - When you want to keep something permanently, call mem_reinforce to
      promote it from short-term to long-term memory.

    ### When to associate
    - When two concepts are related, call mem_associate to link them.
    - Use only supported relationships: contradicts, context_for, example_of,
      reinforces, or related.

    ### When to correct or forget
    - When the user corrects remembered information, call mem_update.
    - When the user explicitly retracts remembered information, call mem_forget.

    ### When to reflect
    - Call mem_reflect only when the user explicitly asks to organize compacted
      conversation context into a reviewable memory candidate.

    ### Constraints
    - Never store secrets, credentials, tokens, API keys, or PII.
    - Do not store transient command output or log noise.
    - Do not store obvious facts that any file read would reveal.
    """
  end

  # ── Strict profile ────────────────────────────────────────────────────

  defp strict_prompt do
    """
    ## Memory (Strict Policy)

    You have access to memory tools: mem_recall, mem_learn, mem_reinforce,
    mem_associate, mem_update, mem_forget, and mem_reflect. Follow these rules strictly —
    do not deviate.

    ### When to recall
    - You MUST call mem_recall before starting any task that may involve
      project-specific knowledge, conventions, or user preferences.

    ### When to learn
    - You may call mem_learn ONLY for durable, non-obvious facts that pass
      the content validation checks.
    - Memory starts as short-term (24h expiry) unless reinforced.
    - Do NOT store generic summaries or facts obvious from a quick read.

    ### When to reinforce
    - Call mem_reinforce to promote important short-term memories to long-term.

    ### When to associate
    - Call mem_associate only with a supported relationship: contradicts,
      context_for, example_of, reinforces, or related.

    ### When to correct or forget
    - Call mem_update only to apply an explicit correction to a memory.
    - Call mem_forget only when remembered information is explicitly retracted.

    ### When to reflect
    - Call mem_reflect only after an explicit user request. Reflection creates a
      short-term candidate; it never directly creates long-term memory.

    ### Hard constraints — NEVER violate these
    - NEVER store secrets, credentials, tokens, API keys, passwords, or PII.
    - NEVER auto-save content that may contain sensitive information.
    - NEVER store transient command output or log noise.
    - NEVER store obvious facts that any file read would reveal.
    - If in doubt about whether content is safe to store, do NOT store it.
    """
  end

  # ── Minimal profile ───────────────────────────────────────────────────

  defp minimal_prompt do
    """
    ## Memory

    You have access to memory tools: mem_recall and mem_learn.
    Recall before exploring. Learn durable facts you discover.
    Do not store secrets or noise.
    """
  end
end
