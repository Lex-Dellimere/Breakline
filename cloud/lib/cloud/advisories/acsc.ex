defmodule Cloud.Advisories.ACSC do
  @moduledoc """
  The Australian Cyber Security Centre's alerts and advisories RSS feeds
  (CC BY 4.0: anything shown from them carries "Source: ACSC, CC BY 4.0").

  Items are RSS 2.0 (`title`, `link`, `description`, `pubDate`,
  `dc:creator`, `guid`). CVEs and products appear only in free text, so
  `Cloud.Advisories.TextMatch` extracts them. The same alert can appear more
  than once under different links, so an item's `external_id` is the slug of
  its normalised title and duplicates within a document keep the earliest.

  The xml is parsed with OTP's `:xmerl_sax_parser`, which reports names as
  strings (never atoms), with entity declarations and external entities
  refused.
  """

  alias Cloud.Advisories.TextMatch

  @urls %{
    acsc_alerts: "https://www.cyber.gov.au/rss/alerts",
    acsc_advisories: "https://www.cyber.gov.au/rss/advisories"
  }

  @fields %{
    ~c"title" => "title",
    ~c"link" => "link",
    ~c"description" => "description",
    ~c"pubDate" => "pubDate",
    ~c"guid" => "guid",
    ~c"creator" => "creator"
  }

  @doc "The url of an ACSC feed (`:acsc_alerts` or `:acsc_advisories`)."
  @spec url(atom()) :: String.t()
  def url(feed), do: Map.fetch!(@urls, feed)

  @doc "Fetches a feed with a conditional GET, see `Cloud.Advisories.HTTP.get/3`."
  @spec fetch(atom(), map(), keyword()) :: Cloud.Advisories.HTTP.result()
  def fetch(feed, validators, opts \\ []),
    do: Cloud.Advisories.HTTP.get(url(feed), validators, opts)

  @doc """
  Parses an RSS document into advisory attribute maps (see
  `Cloud.Advisories.Advisory`), without `:baseline?`. `tool_ids` here are
  the name matches only; `Cloud.Advisories.Poller` adds the tools of KEV
  advisories for the item's CVEs.
  """
  @spec parse(binary(), atom()) :: {:ok, [map()]} | {:error, term()}
  def parse(body, feed) when is_binary(body) do
    with {:ok, items} <- items(body) do
      entries =
        items
        |> Enum.flat_map(&entry(&1, feed))
        |> Enum.group_by(& &1.external_id)
        |> Enum.map(fn {_id, dupes} -> Enum.min_by(dupes, &sort_key/1) end)
        |> Enum.sort_by(&sort_key/1)

      {:ok, entries}
    end
  end

  @doc """
  The slug an ACSC title is deduplicated by: lowercase letters and digits
  joined by single dashes, at most 200 characters.

      iex> Cloud.Advisories.ACSC.slug("  Critical vulnerabilities in  Fortinet products ")
      "critical-vulnerabilities-in-fortinet-products"
  """
  @spec slug(String.t()) :: String.t()
  def slug(title) do
    title
    |> String.downcase()
    |> then(&Regex.replace(~r/[^\p{L}\p{N}]+/u, &1, "-"))
    |> String.trim("-")
    |> String.slice(0, 200)
  end

  # earliest first; items without a date last
  defp sort_key(%{published_at: nil, link: link}), do: {1, 0, link}

  defp sort_key(%{published_at: at, link: link}),
    do: {0, DateTime.to_unix(at, :microsecond), link}

  # xml

  defp items(body) do
    state = %{item: nil, field: nil, text: [], items: []}

    try do
      case :xmerl_sax_parser.stream(body, [
             :disallow_entities,
             {:external_entities, :none},
             {:event_fun, &event/3},
             {:event_state, state}
           ]) do
        {:ok, %{items: items}, _rest} -> {:ok, Enum.reverse(items)}
        {_kind, _location, reason, _end_tags, _state} -> {:error, {:invalid_xml, inspect(reason)}}
      end
    catch
      kind, reason -> {:error, {:invalid_xml, inspect({kind, reason})}}
    end
  end

  defp event({:startElement, _uri, ~c"item", _qname, _attrs}, _location, state),
    do: %{state | item: %{}, field: nil, text: []}

  defp event({:startElement, _uri, name, _qname, _attrs}, _location, %{item: %{}} = state),
    do: %{state | field: Map.get(@fields, name), text: []}

  defp event({:characters, chars}, _location, %{item: %{}, field: field} = state)
       when is_binary(field),
       do: %{state | text: [state.text | [chars]]}

  defp event({:endElement, _uri, ~c"item", _qname}, _location, %{item: %{} = item} = state),
    do: %{state | item: nil, field: nil, items: [item | state.items]}

  defp event({:endElement, _uri, _name, _qname}, _location, %{item: %{}, field: field} = state)
       when is_binary(field) do
    text = state.text |> List.flatten() |> List.to_string()
    %{state | item: Map.put(state.item, field, text), field: nil, text: []}
  end

  defp event(_event, _location, state), do: state

  # entries

  defp entry(item, feed) do
    title = clean(item["title"])

    case title && slug(title) do
      slug when is_binary(slug) and slug != "" ->
        description = item["description"] |> strip_tags() |> clean()
        text = Enum.join(Enum.reject([title, description], &is_nil/1), " ")
        name_tools = TextMatch.tool_ids(text)

        [
          %{
            source: :acsc,
            external_id: slug,
            title: String.slice(title, 0, 1000),
            cves: TextMatch.cves(text),
            vendor: nil,
            product: nil,
            tool_ids: name_tools,
            exploitation: TextMatch.exploitation(title, description || ""),
            published_at: pub_date(item["pubDate"]),
            link: link(item),
            raw:
              item
              |> Map.put("feed", Atom.to_string(feed))
              |> Map.put("match", %{"names" => name_tools, "kev" => []})
          }
        ]

      _ ->
        []
    end
  end

  defp link(item) do
    [item["link"], item["guid"]]
    |> Enum.map(&clean/1)
    |> Enum.find(&(is_binary(&1) and String.starts_with?(&1, "https://")))
  end

  defp clean(nil), do: nil

  defp clean(text) do
    case text |> String.split() |> Enum.join(" ") do
      "" -> nil
      text -> text
    end
  end

  defp strip_tags(nil), do: nil
  defp strip_tags(html), do: Regex.replace(~r/<[^>]*>/, html, " ")

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @rfc822 ~r/^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+([+-]\d{4}|GMT|UTC|Z)$/

  @doc false
  # rss pubDate (rfc 822 / 1123) to a utc datetime, nil when unreadable
  @spec pub_date(String.t() | nil) :: DateTime.t() | nil
  def pub_date(nil), do: nil

  def pub_date(value) do
    with [_, day, month, year, hour, minute, second, zone] <-
           Regex.run(@rfc822, String.trim(value), capture: :all) |> pad_seconds(),
         month when is_integer(month) <-
           Enum.find_index(@months, &(&1 == String.downcase(month))),
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(year),
             month + 1,
             String.to_integer(day),
             String.to_integer(hour),
             String.to_integer(minute),
             String.to_integer(second)
           ) do
      naive
      |> NaiveDateTime.add(-offset_seconds(zone), :second)
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.add(0, :microsecond)
    else
      _ -> nil
    end
  end

  defp pad_seconds([_, _, _, _, _, _, "", _] = parts), do: List.replace_at(parts, 6, "0")
  defp pad_seconds(parts), do: parts

  defp offset_seconds(zone) when zone in ["GMT", "UTC", "Z"], do: 0

  defp offset_seconds(<<sign, hours::binary-size(2), minutes::binary-size(2)>>) do
    seconds = String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60
    if sign == ?-, do: -seconds, else: seconds
  end
end
