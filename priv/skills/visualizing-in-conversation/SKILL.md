---
name: visualizing-in-conversation
description: Create chat-embedded interactive explanations, charts, reports, simulators, and small UIs when interaction improves an answer; not for standalone websites or project pages.
---

# Visualizing in conversation

Build an interactive surface inside a Handbean Web conversation. This is a presentation layer for an answer, not a second runtime: the Agent remains the owner of tools, resources, permissions, and real task execution. The widget source is part of the assistant message and persists with the transcript.

## When to use it

Use a widget when interaction materially helps the user understand or explore the answer, such as:

- filtering, sorting, or charting a bounded report;
- changing assumptions in a calculator or simulator;
- exploring an explanation, comparison, timeline, or decision aid;
- collecting visible choices for a follow-up request.

Do not use a widget when prose, Markdown, a table, or a static image communicates the answer just as well. Do not use it for a standalone website, a project page, a reusable application, background automation, or decoration alone.

A widget presents information and collects local interaction. It does not perform the user's real task.

## Output contract

Return a self-contained fenced `widget` block, with any explanation outside it in ordinary Markdown:

````markdown
```widget
<style>/* inline styles */</style>
<div><!-- semantic markup --></div>
<script>/* vanilla JavaScript */</script>
```
````

Keep all HTML, CSS, JavaScript, and bounded data inside the block. Use vanilla JavaScript and browser primitives. Do not use packages, imports, CDNs, external scripts, or external fonts.

While the fence is incomplete, Handbean may render its markup but scripts remain paused. The bridge exists only after the closing fence, when the widget runs in an opaque-origin iframe under a strict CSP. It cannot access the parent DOM, cookies, browser storage, host tools, host resources, original attachments, the network, or form submission. Do not try to bypass these boundaries or imply those capabilities exist.

Treat embedded user data as untrusted text. Prefer `textContent` and DOM APIs over HTML string concatenation; do not use `eval`. Serialize inline JSON safely so data cannot terminate its containing element or script.

## Local UI state

After the fence closes, the widget can use:

- `window.handbean.getState()` to read its local transient UI state;
- `window.handbean.setState(value)` to replace that state.

The value must be JSON-serializable and no larger than 16 KiB when serialized. Keep only presentation state such as selected tabs, filters, sort order, or simulator inputs. Do not treat it as durable application data, a source of truth, or a place for hidden instructions or model-only data. Handle an empty initial state and state errors without breaking the widget.

## Visible follow-ups only

To let the user continue with the Agent, call:

```javascript
window.handbean.prefillFollowUp({
  prompt: "Visible, self-contained follow-up for the user to review",
  selections: [{label: "Visible choice", value: "chosen-value"}]
});
```

The payload shape is strictly `{prompt, selections?}`:

- `prompt` is a non-empty string that fully and visibly states what the user would ask the Agent to do.
- `selections`, when present, is an array of visible `{label, value}` choices; each value is a string, number, or boolean.
- Do not add other keys, tool names, resource identifiers, hidden context, or model-only data.

This call only prefills the Composer. It does not send a message, invoke a tool, submit a form, or complete an action. The user must be able to inspect and edit the text, then explicitly send it. Only that ordinary user message may start real work through the Agent's existing permission chain. Therefore every fact or choice the Agent needs must be visible in the Composer text; optional `selections` may structure visible choices, not conceal information from the user.

Never claim that prefilling performed the requested action.

## Reports from uploaded data

If the user uploaded data, the Agent must first read and parse it through Handbean's existing attachment and tool chain. After parsing, embed only the necessary, appropriately reduced data directly in the widget source, for example as safely serialized inline JSON. The widget may then filter, sort, aggregate, and chart that bounded local copy.

The widget must not read the original attachment, open a host path, dereference an attachment or resource identifier, or fetch more data. Do not invent a large-data resource protocol, hidden data handle, or direct-upload URL. If the necessary data is too large to embed responsibly, provide a smaller summary, ask the user to narrow the scope, or let a later user message ask the Agent to process another slice.

## Editable drafts and candidate sets

Use local controls for edits that do not need the Agent yet. Keep the current draft in the widget while the user changes fields, dates, owners, dependencies, weights, filters, sort order, and selected rows. Deleting a row locally does not perform a real task.

When the user chooses to continue, serialize the current edited subset into the visible `prompt`. A multiline Markdown list or table is appropriate for structured rows. Do not send only opaque row IDs when the Agent needs the edited values.

For a batch task or schedule draft, include every selected task's visible title, owner, date, dependencies, and other fields needed for creation. The button may say “Review selected tasks” or “Continue with selected tasks”, but `prefillFollowUp` still only prepares the Composer; actual creation happens after the user reviews and sends the message and the Agent uses its existing task or scheduling tools.

For a filtered candidate comparison, include the active budget, preference weights, relevant filters, source/update context, and the selected candidates' identifying facts in the visible prompt. A button such as “Continue investigating these candidates” should ask the Agent to investigate exactly that visible subset. Local filtering and sorting never require a follow-up.

Build rich follow-ups in `prompt`; use `selections` only as a convenience for compact visible scalar choices. The complete request must remain understandable and editable from the Composer text alone. Keep the total follow-up payload within 8 KiB. For a larger draft, submit a smaller selected batch rather than hiding data elsewhere.

## Interaction quality

- Make the layout responsive at narrow chat widths and avoid fixed-width overflow.
- Use semantic elements, associated labels, and real buttons and controls.
- Support keyboard operation and visible focus; expose useful names and states to assistive technology.
- Do not rely on color alone, and keep text and controls legible in light and dark color schemes.
- Explain units, scales, assumptions, empty states, and errors where relevant.
- Keep controls and visual hierarchy focused on the user's question.

## Verify before presenting

Check that:

1. the fence closes and the widget is self-contained;
2. initial rendering and interactions work without network access;
3. state remains JSON-serializable and within 16 KiB;
4. narrow layouts, keyboard use, focus, labels, and contrast remain usable;
5. any follow-up uses exactly `{prompt, selections?}`, visibly prefills the Composer, and does not claim execution;
6. uploaded-data widgets contain only the reduced parsed copy and never attempt to read the original attachment.

Use a real rendered Web view when one is available. Never say the widget was tested or verified unless you actually performed that check.
