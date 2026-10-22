defmodule HandbeanWeb.WorkspaceLive.ConversationSearchComponents do
  @moduledoc false

  use HandbeanWeb, :html

  attr :search, :map, required: true
  attr :workspaces, :list, required: true

  def conversation_search_palette(assigns) do
    ~H"""
    <div
      id="conversation-search-overlay"
      class="conversation-search-overlay"
      hidden={not @search.open?}
      phx-hook="ConversationSearch"
      data-results-query={@search.results_query}
      role="presentation"
    >
      <section
        id="conversation-search-dialog"
        class="conversation-search-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="conversation-search-title"
      >
        <h2 id="conversation-search-title" class="sr-only">{gettext("Search conversations")}</h2>
        <form
          id="conversation-search-form"
          phx-change="conversation_search"
          class="conversation-search-form"
        >
          <div class="conversation-search-input-row">
            <svg
              width="19"
              height="19"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              aria-hidden="true"
            >
              <circle cx="10.5" cy="10.5" r="6.5" />
              <path d="m15.5 15.5 4.5 4.5" />
            </svg>
            <label class="sr-only" for="conversation-search-input">
              {gettext("Search titles, user messages, and assistant replies")}
            </label>
            <input
              id="conversation-search-input"
              name="search[query]"
              type="search"
              value={@search.query}
              placeholder={gettext("Search titles, user messages, assistant replies…")}
              autocomplete="off"
              phx-debounce="200"
              role="combobox"
              aria-autocomplete="list"
              aria-expanded={to_string(@search.open?)}
              aria-controls="conversation-search-results"
            />
            <input type="hidden" name="search[content]" value={@search.content} />
            <button
              id="conversation-search-close"
              type="button"
              phx-click="close_conversation_search"
              class="conversation-search-close"
              aria-label={gettext("Close search")}
            >×</button>
          </div>
          <div class="conversation-search-toolbar">
            <div
              class="conversation-search-filters"
              role="group"
              aria-label={gettext("Search content")}
            >
              <button
                :for={{value, label} <- content_filters()}
                type="button"
                phx-click="conversation_search_content"
                phx-value-content={value}
                aria-pressed={to_string(@search.content == value)}
              >{label}</button>
            </div>
            <select name="search[range]" aria-label={gettext("Conversation range")}>
              <option value="all" selected={@search.range == "all"}>
                {gettext("All conversations")}
              </option>
              <option value="free" selected={@search.range == "free"}>{gettext("Free chat")}</option>
              <option
                :for={workspace <- @workspaces}
                value={"workspace:#{workspace["id"]}"}
                selected={@search.range == "workspace:#{workspace["id"]}"}
              >
                {workspace["name"]}
              </option>
            </select>
          </div>
        </form>

        <div class="conversation-search-caption">
          <span>{if @search.query == "",
            do: gettext("Recent conversations"),
            else: gettext("Matching conversations")}</span>
          <span :if={@search.incomplete?} role="status">
            {gettext("Search not complete — continue searching")}
          </span>
        </div>

        <div
          id="conversation-search-results"
          class="conversation-search-results"
          role="listbox"
          aria-label={gettext("Conversation search results")}
        >
          <div
            :if={@search.loading? and @search.results == []}
            class="conversation-search-empty"
            role="status"
          >
            <strong>{gettext("Searching conversations…")}</strong>
          </div>
          <div
            :if={not @search.loading? and @search.error}
            class="conversation-search-empty"
            role="alert"
          >
            <strong>{@search.error}</strong>
          </div>
          <div
            :if={
              not @search.loading? and is_nil(@search.error) and @search.results == [] and
                @search.incomplete?
            }
            class="conversation-search-empty"
            role="status"
          >
            <strong>{gettext("Search paused before all conversations were checked")}</strong>
            <span>{gettext("Continue searching to check older conversations and messages.")}</span>
          </div>
          <div
            :if={
              not @search.loading? and is_nil(@search.error) and @search.results == [] and
                not @search.incomplete?
            }
            class="conversation-search-empty"
          >
            <strong>{gettext("No matching conversations")}</strong>
            <span>{gettext("Try another term or search range.")}</span>
          </div>

          <div
            :for={{result, result_index} <- Enum.with_index(@search.results)}
            class="conversation-search-result-group"
          >
            <button
              id={"conversation-search-result-#{result_index}"}
              type="button"
              role="option"
              aria-selected="false"
              class="conversation-search-result"
              data-search-option
              phx-click="open_conversation_search_hit"
              phx-value-conversation_id={result.conversation_id}
            >
              <span class="conversation-search-headline">
                <span class="conversation-search-dot" aria-hidden="true"></span>
                <span
                  class="conversation-search-title"
                  data-safe-highlight
                  data-highlight-query={if(result.title_match, do: @search.query, else: "")}
                >{result.title}</span>
                <span class="conversation-search-meta">
                  {result.workspace_label}{if result.archived, do: " · #{gettext("Archived")}"}
                </span>
              </span>
            </button>
            <button
              :for={{match, match_index} <- Enum.with_index(result.matches)}
              id={"conversation-search-result-#{result_index}-#{match_index}"}
              type="button"
              role="option"
              aria-selected="false"
              class="conversation-search-snippet"
              data-search-option
              phx-click="open_conversation_search_hit"
              phx-value-conversation_id={result.conversation_id}
              phx-value-entry_id={match.entry_id}
            >
              <span class="conversation-search-source">{source_label(match.source)}</span>
              <span data-safe-highlight data-highlight-query={@search.query}>{match.snippet}</span>
            </button>
          </div>

          <button
            :if={@search.next_cursor}
            type="button"
            class="conversation-search-more"
            data-search-continuation
            phx-click="load_more_conversation_search"
            disabled={@search.loading?}
          >
            {if @search.loading?,
              do: gettext("Searching conversations…"),
              else:
                if(@search.incomplete?, do: gettext("Continue search"), else: gettext("Load more"))}
          </button>
        </div>

        <footer class="conversation-search-footer">
          <span><kbd>↑↓</kbd> {gettext("Select")}</span>
          <span><kbd>↵</kbd> {gettext("Open")}</span>
          <span><kbd>Esc</kbd> {gettext("Close")}</span>
          <span class="conversation-search-footer-scope">{gettext("Includes archived conversations")}</span>
        </footer>
        <div class="sr-only" role="status" aria-live="polite">
          {ngettext("%{count} conversation", "%{count} conversations", length(@search.results),
            count: length(@search.results)
          )}
        </div>
      </section>
    </div>
    """
  end

  defp content_filters do
    [
      {"all", gettext("All")},
      {"title", gettext("Title")},
      {"user", gettext("User input")},
      {"assistant", gettext("Assistant reply")}
    ]
  end

  defp source_label("user"), do: gettext("User input")
  defp source_label("assistant"), do: gettext("Assistant reply")
end
