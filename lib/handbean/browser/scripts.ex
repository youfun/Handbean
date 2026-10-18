defmodule Handbean.Browser.Scripts do
  @moduledoc """
  One-shot evaluateJavascript payloads for the bridgeless browser.

  Results return through ValueCallback, never `window.mob.send`.
  Scripts do not leave a JS interface on the page.
  """

  def snapshot_js do
    """
    (function(){
      var nodes = document.querySelectorAll('a,button,input,textarea,select,[role=button]');
      var items = [];
      for (var i=0;i<nodes.length && items.length<40;i++){
        var el = nodes[i];
        var t = (el.innerText||el.value||el.getAttribute('aria-label')||el.getAttribute('placeholder')||'').trim().slice(0,80);
        if(!t) continue;
        el.setAttribute('data-handbean-ref', String(items.length));
        items.push({ref:String(items.length), tag:(el.tagName||'').toLowerCase(), text:t});
      }
      var body = (document.body && document.body.innerText) ? document.body.innerText : '';
      return JSON.stringify({
        action:'snapshot',
        url:location.href,
        title:document.title||'',
        text:body.slice(0,4000),
        items:items,
        hasMob: typeof window.mob
      });
    })();
    """
  end

  def wrap_eval(js) when is_binary(js) do
    """
    (function(){
      try {
        var result = (function(){ #{js} })();
        return JSON.stringify({action:'eval', ok:true, result:String(result)});
      } catch(e) {
        return JSON.stringify({action:'eval', ok:false, error:String(e)});
      }
    })();
    """
  end

  def click_js(ref) when is_binary(ref) do
    selector = js_string(~s([data-handbean-ref="#{ref}"]))

    """
    (function(){
      var el = document.querySelector(#{selector});
      if(!el) return JSON.stringify({action:'click', ok:false, error:'not found'});
      el.click();
      return JSON.stringify({action:'click', ok:true});
    })();
    """
  end

  def fill_js(ref, value) when is_binary(ref) do
    selector = js_string(~s([data-handbean-ref="#{ref}"]))
    value = js_string(value)

    """
    (function(){
      var el = document.querySelector(#{selector});
      if(!el) return JSON.stringify({action:'fill', ok:false, error:'not found'});
      el.focus();
      el.value = #{value};
      el.dispatchEvent(new Event('input', {bubbles:true}));
      el.dispatchEvent(new Event('change', {bubbles:true}));
      return JSON.stringify({action:'fill', ok:true});
    })();
    """
  end

  def format_snapshot(msg) when is_map(msg) do
    msg = stringify_keys(msg)
    title = msg["title"] || ""
    url = msg["url"] || ""
    text = msg["text"] || ""
    items = msg["items"] || []

    item_lines =
      Enum.map(items, fn item ->
        item = if is_map(item), do: stringify_keys(item), else: %{}
        "[#{item["ref"]}] #{item["tag"]} #{item["text"]}"
      end)

    Enum.join(["url: #{url}", "title: #{title}", "text:", text, "elements:"] ++ item_lines, "\n")
  end

  def format_reply(%{"action" => "snapshot"} = msg), do: format_snapshot(msg)

  def format_reply(msg) when is_map(msg) do
    case Handbean.JSON.encode(msg) do
      {:ok, json} -> json
      _ -> inspect(msg)
    end
  end

  def format_reply(other) when is_binary(other), do: other
  def format_reply(other), do: inspect(other)

  def decode_eval_result(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    json =
      cond do
        String.starts_with?(trimmed, "\"") ->
          case Handbean.JSON.decode(trimmed) do
            {:ok, inner} when is_binary(inner) -> inner
            _ -> trimmed
          end

        true ->
          trimmed
      end

    case Handbean.JSON.decode(json) do
      {:ok, map} when is_map(map) -> stringify_keys(map)
      _ -> %{"raw" => trimmed}
    end
  end

  def decode_eval_result(other), do: %{"raw" => inspect(other)}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(map) when is_map(map), do: stringify_keys(map)
  defp stringify_value(value), do: value

  defp js_string(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> then(&"\"#{&1}\"")
  end
end
