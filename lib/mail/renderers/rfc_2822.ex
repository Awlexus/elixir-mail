defmodule Mail.Renderers.RFC2822 do
  import Mail.Message, only: [match_content_type?: 2]

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @moduledoc """
  RFC2822 Parser

  Will attempt to render a valid RFC2822 message
  from a `%Mail.Message{}` data model.

      Mail.Renderers.RFC2822.render(message)

  The email validation regex defaults to `~r/\w+@\w+\.\w+/`
  and can be overridden with the following config:

      config :mail, email_regex: custom_regex
  """

  @blacklisted_headers ["bcc"]
  @address_types ["From", "To", "Reply-To", "Cc", "Bcc"]

  # https://tools.ietf.org/html/rfc5322#section-2.1.1
  @max_line_length 78

  # A msg-id must stay intact, so these headers are not encoded (RFC 2047 §5.3)
  @unencoded_headers [
    # RFC 5322
    "Message-Id",
    "In-Reply-To",
    "References",
    "Resent-Message-Id",
    # RFC 2045
    "Content-Id"
  ]

  # https://tools.ietf.org/html/rfc2822#section-3.4.1
  @email_validation_regex Application.compile_env(
                            :mail,
                            :email_regex,
                            ~r/[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}/
                          )

  @doc """
  Renders a message according to the RFC2822 spec
  """
  def render(%Mail.Message{multipart: true} = message) do
    message
    |> reorganize
    |> Mail.Message.put_header(:mime_version, "1.0")
    |> render_part()
  end

  def render(%Mail.Message{} = message),
    do: render_part(message)

  @doc """
  Render an individual part

  An optional function can be passed used during the rendering of each
  individual part
  """
  def render_part(message, render_part_function \\ &render_part/1)

  def render_part(%Mail.Message{multipart: true} = message, fun) do
    boundary = Mail.Message.get_boundary(message)
    message = Mail.Message.put_boundary(message, boundary)

    headers = render_headers(message.headers, @blacklisted_headers)
    boundary = "--#{boundary}"

    parts =
      render_parts(message.parts, fun)
      |> Enum.join("\r\n#{boundary}\r\n")

    "#{headers}\r\n\r\n#{boundary}\r\n#{parts}\r\n#{boundary}--"
  end

  def render_part(%Mail.Message{} = message, _fun) do
    encoded_body = encode(message.body, message)
    "#{render_headers(message.headers, @blacklisted_headers)}\r\n\r\n#{encoded_body}"
  end

  def render_parts(parts, fun \\ &render_part/1) when is_list(parts),
    do: Enum.map(parts, &fun.(&1))

  defp render_header({key, value}), do: render_header(key, value)

  @doc """
  Will render a given header according to the RFC2822 spec
  """
  def render_header(key, value)

  def render_header(_key, nil), do: nil
  def render_header(_key, []), do: nil
  def render_header(_key, ""), do: nil
  def render_header(key, <<" ", rest::binary>>), do: render_header(key, rest)

  def render_header(key, value) when is_atom(key),
    do: render_header(Atom.to_string(key), value)

  def render_header(key, value) do
    key =
      key
      |> String.replace("_", "-")
      |> String.split("-")
      |> Enum.map(&String.capitalize(&1))
      |> Enum.join("-")

    fold_header(key, render_header_value(key, value))
  end

  defp render_header_value("Date", date_time),
    do: timestamp_from_datetime(date_time)

  # Every address goes on a line of its own
  defp render_header_value(address_type, addresses)
       when is_list(addresses) and address_type in @address_types,
       do:
         addresses
         |> Enum.map(&render_address(&1))
         |> Enum.join(",\r\n ")

  defp render_header_value(address_type, address) when address_type in @address_types,
    do: render_address(address)

  defp render_header_value("Content-Transfer-Encoding" = key, value) when is_atom(value) do
    value =
      value
      |> Atom.to_string()
      |> String.replace("_", "-")

    render_header_value(key, value)
  end

  defp render_header_value(header, value) when header in @unencoded_headers do
    value
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
  end

  defp render_header_value(_key, [value | subtypes]),
    do:
      Enum.join([encode_header_value(value, :quoted_printable) | render_subtypes(subtypes)], "; ")

  defp render_header_value(key, value),
    do: render_header_value(key, List.wrap(value))

  def validate_address(nil), do: raise(ArgumentError, message: "Email address cannot be nil")

  def validate_address(address) do
    case Regex.match?(@email_validation_regex, address) do
      true ->
        address

      false ->
        raise ArgumentError,
          message: """
          The email address `#{address}` is invalid.
          """
    end
  end

  defp render_address({name, email}) do
    address = validate_address(email)
    encoded = encode_header_value(name, :quoted_printable)

    if encoded == name do
      ~s("#{name}" <#{address}>)
    else
      "#{encoded} <#{address}>"
    end
  end

  defp render_address(email), do: validate_address(email)

  defp render_subtypes([]), do: []

  defp render_subtypes([{key, value} | subtypes]) when is_atom(key),
    do: render_subtypes([{Atom.to_string(key), value} | subtypes])

  defp render_subtypes([{"boundary", value} | subtypes]) do
    [~s(boundary="#{value}") | render_subtypes(subtypes)]
  end

  defp render_subtypes([{key, value} | subtypes]) do
    key = String.replace(key, "_", "-")
    value = encode_header_value(value, :quoted_printable)

    value =
      if value =~ ~r/[\s()<>@,;:\\<\/\[\]?=]/ do
        "\"#{value}\""
      else
        value
      end

    ["#{key}=#{value}" | render_subtypes(subtypes)]
  end

  @doc """
  Will render all headers according to the RFC2822 spec

  Can take an optional list of headers to blacklist
  """
  def render_headers(headers, blacklist \\ [])

  def render_headers(map, blacklist) when is_map(map) do
    map
    |> Map.to_list()
    |> render_headers(blacklist)
  end

  def render_headers(list, blacklist) when is_list(list) do
    list
    |> Enum.reject(&Enum.member?(blacklist, elem(&1, 0)))
    |> Enum.map(&render_header/1)
    |> Enum.filter(& &1)
    |> Enum.reverse()
    |> Enum.join("\r\n")
  end

  # Per RFC 2047, encoding is only required for non-ASCII characters and control
  # characters.  Ordinary ASCII-only headers should not be encoded, regardless of length.
  defp encode_header_value(header_value, :quoted_printable) do
    if requires_encoding?(header_value) do
      Mail.Encoders.EncodedWord.encode(header_value)
    else
      header_value
    end
  end

  # Return true if any characters found that require quoted-printable encoding.
  # ( >0x7F require escaping (non-ASCII), 0x7F and <0x20 (except \t) are control
  # characters and also need encoding. )
  defp requires_encoding?(<<>>), do: false
  defp requires_encoding?(<<byte, _rest::binary>>) when byte > 126, do: true
  defp requires_encoding?(<<byte, _rest::binary>>) when byte < 32 and byte != ?\t, do: true
  defp requires_encoding?(<<_byte, rest::binary>>), do: requires_encoding?(rest)

  # Wraps a header onto continuation lines within the line length of RFC 5322 §2.1.1. The CRLF goes
  # in front of the whitespace that separates two tokens, so that unfolding restores the value
  # unchanged. A token longer than the line length has no fold point and stays as it is, which keeps
  # a msg-id intact.
  defp fold_header(key, value) do
    value
    |> fold_segments()
    |> Enum.reduce(key <> ": ", fn {whitespace, token}, folded ->
      if fold?(key, folded, whitespace, token) do
        folded <> "\r\n" <> whitespace <> token
      else
        folded <> whitespace <> token
      end
    end)
  end

  defp fold?(key, folded, whitespace, token) do
    whitespace != "" and token != "" and not angle_address?(key, token) and
      line_length(folded) + byte_size(whitespace) + byte_size(token) > @max_line_length
  end

  # An address header is only folded between its addresses and within an encoded name, so that the
  # name and the address of one recipient stay on the same line
  defp angle_address?(key, token),
    do: key in @address_types and String.starts_with?(token, "<")

  # The length of the line that a header ends on, which is the whole header until it is folded
  defp line_length(folded) do
    folded
    |> :binary.split("\r\n", [:global])
    |> List.last()
    |> byte_size()
  end

  # Splits a rendered header value into `{whitespace, token}` segments. Whitespace within a quoted
  # string is no fold point, so quoted names and quoted parameters keep their spaces on one line.
  defp fold_segments(value), do: fold_segments(value, "", "", [], false)

  defp fold_segments(<<>>, whitespace, token, segments, _in_quotes),
    do: Enum.reverse([{whitespace, token} | segments])

  defp fold_segments(<<?", rest::binary>>, whitespace, token, segments, in_quotes),
    do: fold_segments(rest, whitespace, token <> ~s("), segments, !in_quotes)

  defp fold_segments(<<char, rest::binary>>, whitespace, "", segments, false)
       when char in [?\s, ?\t],
       do: fold_segments(rest, whitespace <> <<char>>, "", segments, false)

  defp fold_segments(<<char, rest::binary>>, whitespace, token, segments, false)
       when char in [?\s, ?\t],
       do: fold_segments(rest, <<char>>, "", [{whitespace, token} | segments], false)

  defp fold_segments(<<char, rest::binary>>, whitespace, token, segments, true)
       when char in [?\s, ?\t] do
    if between_encoded_words?(token, rest) do
      fold_segments(rest, <<char>>, "", [{whitespace, token} | segments], true)
    else
      fold_segments(rest, whitespace, token <> <<char>>, segments, true)
    end
  end

  defp fold_segments(<<char, rest::binary>>, whitespace, token, segments, in_quotes),
    do: fold_segments(rest, whitespace, token <> <<char>>, segments, in_quotes)

  # RFC 2047 §6.2 ignores the whitespace between two adjacent encoded words, so a fold there leaves
  # the value unchanged even within a quoted string, where a fold is otherwise avoided.
  defp between_encoded_words?(token, rest),
    do: String.ends_with?(token, "?=") and String.starts_with?(rest, "=?")

  @doc """
  Builds a RFC2822 timestamp from an Erlang timestamp

  [RFC2822 3.3 - Date and Time Specification](https://tools.ietf.org/html/rfc2822#section-3.3)

  This function always assumes the Erlang timestamp is in Universal time, not Local time
  """
  def timestamp_from_datetime({{year, month, day} = date, {hour, minute, second}}) do
    day_name = day_name(:calendar.day_of_the_week(date))
    month_name = Enum.at(@months, month - 1)

    date_part = "#{day_name}, #{day} #{month_name} #{year}"
    time_part = "#{pad(hour)}:#{pad(minute)}:#{pad(second)}"

    date_part <> " " <> time_part <> " +0000"
  end

  def timestamp_from_datetime(%DateTime{} = datetime) do
    %{
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      utc_offset: utc_offset,
      std_offset: std_offset
    } = datetime

    day_name = Enum.at(@days, :calendar.day_of_the_week({year, month, day}) - 1)
    month_name = Enum.at(@months, month - 1)

    date_part = "#{day_name}, #{day} #{month_name} #{year}"
    time_part = "#{pad(hour)}:#{pad(minute)}:#{pad(second)}"

    date_part <> " " <> time_part <> " " <> render_time_zone(utc_offset, std_offset)
  end

  defp render_time_zone(utc_offset, std_offset) do
    offset = abs(utc_offset + std_offset)
    minutes = div(rem(offset, 3600), 60)
    hours = div(offset, 3600)

    if(utc_offset >= 0, do: "+", else: "-") <> "#{pad(hours)}#{pad(minutes)}"
  end

  @days
  |> Enum.with_index(1)
  |> Enum.each(fn {day, index} ->
    defp day_name(unquote(index)), do: unquote(day)
  end)

  defp pad(num) do
    num
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end

  defp reorganize(%Mail.Message{multipart: true, headers: headers} = message) do
    {text_parts, attachments} =
      message.parts
      |> Enum.split_with(&match_content_type?(&1, ~r/text\/(plain|html)/))

    {inline_attachments, other_attachments} =
      Enum.split_with(attachments, &Mail.Message.is_attachment?(&1, :inline))

    message =
      if Enum.empty?(text_parts) do
        Mail.Message.put_content_type(message, "multipart/mixed")
      else
        alternative =
          if match?([_part], text_parts) && attachments != [] do
            List.first(text_parts)
          else
            Mail.build_multipart()
            |> Mail.Message.put_content_type("multipart/alternative")
            |> Mail.Message.put_parts(text_parts)
          end

        related =
          if Enum.empty?(inline_attachments) do
            alternative
          else
            Mail.build_multipart()
            |> Mail.Message.put_content_type("multipart/related")
            |> Mail.Message.put_part(alternative)
            |> Mail.Message.put_parts(inline_attachments)
          end

        if Enum.empty?(other_attachments) do
          related
        else
          Mail.build_multipart()
          |> Mail.Message.put_content_type("multipart/mixed")
          |> Mail.Message.put_part(related)
          |> Mail.Message.put_parts(other_attachments)
        end
      end

    Mail.Message.put_headers(message, headers)
  end

  defp encode(body, message) do
    Mail.Encoder.encode(body, Mail.Message.get_header(message, "content-transfer-encoding"))
  end
end
