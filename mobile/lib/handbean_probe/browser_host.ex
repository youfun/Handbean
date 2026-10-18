defmodule HandbeanProbe.BrowserHost do
  @moduledoc """
  JS helpers and reply formatting for the on-device browser pane.

  The pane itself lives on `HandbeanProbe.HomeScreen` so chat stays visible.
  """

  def decode_payload(payload) when is_binary(payload) do
    case Handbean.JSON.decode(payload) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  def decode_payload(payload) when is_map(payload), do: stringify_keys(payload)
  def decode_payload(_), do: %{}

  def format_reply(%{"action" => "snapshot"} = msg) do
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

  def format_reply(msg) do
    case Handbean.JSON.encode(msg) do
      {:ok, json} -> json
      _ -> inspect(msg)
    end
  end

  def snapshot_js do
    """
    (function(){
      function send(d){ try { window.mob.send(d); } catch(e) {} }
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
      send({kind:'handbean_browser', action:'snapshot', url:location.href, title:document.title||'', text:body.slice(0,4000), items:items});
    })();
    """
  end

  def wrap_eval(js) do
    """
    (function(){
      function send(d){ try { window.mob.send(d); } catch(e) {} }
      try {
        var result = (function(){ #{js} })();
        send({kind:'handbean_browser', action:'eval', ok:true, result:String(result)});
      } catch(e) {
        send({kind:'handbean_browser', action:'eval', ok:false, error:String(e)});
      }
    })();
    """
  end

  def click_js(ref) do
    selector = js_string(~s([data-handbean-ref="#{ref}"]))

    """
    (function(){
      function send(d){ try { window.mob.send(d); } catch(e) {} }
      var el = document.querySelector(#{selector});
      if(!el){ send({kind:'handbean_browser', action:'click', ok:false, error:'not found'}); return; }
      el.click();
      send({kind:'handbean_browser', action:'click', ok:true});
    })();
    """
  end

  def fill_js(ref, value) do
    selector = js_string(~s([data-handbean-ref="#{ref}"]))
    value = js_string(value)

    """
    (function(){
      function send(d){ try { window.mob.send(d); } catch(e) {} }
      var el = document.querySelector(#{selector});
      if(!el){ send({kind:'handbean_browser', action:'fill', ok:false, error:'not found'}); return; }
      el.focus();
      el.value = #{value};
      el.dispatchEvent(new Event('input', {bubbles:true}));
      el.dispatchEvent(new Event('change', {bubbles:true}));
      send({kind:'handbean_browser', action:'fill', ok:true});
    })();
    """
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp js_string(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> then(&"\"#{&1}\"")
  end
end
