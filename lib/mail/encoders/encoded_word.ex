defmodule Mail.Encoders.EncodedWord do
  @moduledoc """
  Encodes header values as "Q" encoded words according to RFC 2047.

  See the following links for reference:
  - <https://tools.ietf.org/html/rfc2047#section-4.2>
  """

  @prefix "=?UTF-8?Q?"
  @suffix "?="

  # RFC 2047 §2 allows 75 characters per encoded word. The lower limit leaves room for what precedes
  # the first encoded word on a line, such as a header name (`Reply-To: `) or a parameter name
  # (` filename="`), so that the line still fits the line length of RFC 5322 §2.1.1.
  @max_word_length 64
  @max_text_length @max_word_length - byte_size(@prefix) - byte_size(@suffix)

  # Characters that an encoded word may carry unencoded: the atom characters of RFC 2822 §3.2.4
  # without `=`, `?` and `_`, which RFC 2047 §4.2 reserves.
  @unencoded_chars ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/^`{|}~"

  @doc """
  Encodes a string into one or more encoded words, separated by a space.

  Each encoded word holds a whole number of characters and is no longer than #{@max_word_length}
  characters, delimiters included. The encoded words break between the words of the string; only a
  word that is longer than one encoded word is broken up itself.

  ## Examples

      Mail.Encoders.EncodedWord.encode("façade")
      "=?UTF-8?Q?fa=C3=A7ade?="
  """
  @spec encode(binary) :: binary
  def encode(string) do
    string
    |> encode_words()
    |> group()
    |> Enum.map_join(" ", &(@prefix <> &1 <> @suffix))
  end

  # Every word but the first keeps the space in front of it, as an underscore per RFC 2047 §4.2(2),
  # so that a break between two encoded words falls between two words of the string.
  defp encode_words(string) do
    [first | rest] = String.split(string, " ")
    words = [encode_characters(first) | Enum.map(rest, &["_" | encode_characters(&1)])]

    Enum.flat_map(words, &group/1)
  end

  # An encoded character is escaped byte by byte. Each character is encoded on its own, so that no
  # character can be split across two encoded words (RFC 2047 §5).
  defp encode_characters(<<>>), do: []

  defp encode_characters(<<char, rest::binary>>) when char in @unencoded_chars,
    do: [<<char>> | encode_characters(rest)]

  defp encode_characters(<<char::utf8, rest::binary>>),
    do: [escape(<<char::utf8>>) | encode_characters(rest)]

  defp encode_characters(<<byte, rest::binary>>), do: [escape(<<byte>>) | encode_characters(rest)]

  defp escape(character) do
    for <<byte <- character>>, into: <<>>, do: "=" <> Base.encode16(<<byte>>)
  end

  # Merges parts into groups that each fit into one encoded word
  defp group(parts) do
    parts
    |> Enum.reduce([], &add_part/2)
    |> Enum.reverse()
  end

  defp add_part(part, [group | groups])
       when byte_size(group) + byte_size(part) <= @max_text_length,
       do: [group <> part | groups]

  defp add_part(part, groups), do: [part | groups]
end
