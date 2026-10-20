defmodule Handbean.Agent.TranscriptPersistence.StateKey do
  @moduledoc false

  alias Handbean.Agent.TranscriptPersistence

  def buffer(conversation_id), do: {TranscriptPersistence, :buffer, conversation_id}
  def last_flush(conversation_id), do: {TranscriptPersistence, :last_flush, conversation_id}

  def thinking_buffer(conversation_id),
    do: {TranscriptPersistence, :thinking_buffer, conversation_id}

  def thinking(conversation_id), do: {TranscriptPersistence, :thinking, conversation_id}

  def assistant(conversation_id),
    do: {TranscriptPersistence, :assistant_entry_id, conversation_id}

  def run_opts(conversation_id), do: {TranscriptPersistence, :run_opts, conversation_id}
  def run_payload(conversation_id), do: {TranscriptPersistence, :run_payload, conversation_id}

  def assistant_segments(conversation_id),
    do: {:handbean_transcript_assistant_segments, conversation_id}

  def assistant_phase(conversation_id),
    do: {:handbean_transcript_assistant_phase, conversation_id}

  def segment_phases(conversation_id),
    do: {:handbean_transcript_segment_phases, conversation_id}

  def provider_items(conversation_id),
    do: {:handbean_transcript_provider_items, conversation_id}

  def turn(conversation_id), do: {TranscriptPersistence, :turn_number, conversation_id}
end
