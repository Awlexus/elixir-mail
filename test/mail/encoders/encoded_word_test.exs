defmodule Mail.Encoders.EncodedWordTest do
  use ExUnit.Case, async: true

  @max_length 64

  test "encodes empty string" do
    assert Mail.Encoders.EncodedWord.encode("") == ""
  end

  test "encodes a short value as a single encoded word" do
    assert Mail.Encoders.EncodedWord.encode("Café résumé") ==
             "=?UTF-8?Q?Caf=C3=A9_r=C3=A9sum=C3=A9?="
  end

  # RFC 2047, section 4.2(2)
  test "encodes a space as an underscore" do
    assert Mail.Encoders.EncodedWord.encode("Löw Jr") == "=?UTF-8?Q?L=C3=B6w_Jr?="
  end

  # RFC 2047, section 4.2(3) and section 5
  test "encodes characters that are not allowed in an atom" do
    assert Mail.Encoders.EncodedWord.encode("a=b?c_d.e,f@g:h;") ==
             "=?UTF-8?Q?a=3Db=3Fc=5Fd=2Ee=2Cf=40g=3Ah=3B?="

    assert Mail.Encoders.EncodedWord.encode("i(j)k<l>m\"n\\o[p]q ü") ==
             "=?UTF-8?Q?i=28j=29k=3Cl=3Em=22n=5Co=5Bp=5Dq_=C3=BC?="
  end

  test "leaves atom characters unencoded" do
    atom_characters = "abcXYZ019!#$%&'*+-/^`{|}~"

    assert Mail.Encoders.EncodedWord.encode("ü" <> atom_characters) ==
             "=?UTF-8?Q?=C3=BC" <> atom_characters <> "?="
  end

  test "encodes control characters" do
    assert Mail.Encoders.EncodedWord.encode("line\r\nbreak\ttab") ==
             "=?UTF-8?Q?line=0D=0Abreak=09tab?="
  end

  test "breaks between words instead of within a word" do
    encoded =
      Mail.Encoders.EncodedWord.encode(
        "Ministerium für Wirtschaft, Tourismus, Landwirtschaft und Forsten"
      )

    [first | rest] = String.split(encoded, " ")

    assert String.starts_with?(first, "=?UTF-8?Q?Ministerium_")
    # Every following encoded word starts with the space of the word it begins with
    assert Enum.all?(rest, &String.starts_with?(&1, "=?UTF-8?Q?_"))
  end

  test "breaks within a word that does not fit into one encoded word" do
    encoded = Mail.Encoders.EncodedWord.encode("kurz " <> String.duplicate("ü", 40))
    [first, second | _rest] = String.split(encoded, " ")

    assert first == "=?UTF-8?Q?kurz?="
    assert String.starts_with?(second, "=?UTF-8?Q?_=C3=BC")
    assert byte_size(second) <= @max_length
  end

  # RFC 2047, section 2
  test "splits long values into encoded words within the maximum length" do
    encoded = Mail.Encoders.EncodedWord.encode(String.duplicate("ü", 100))
    words = String.split(encoded, " ")

    assert length(words) > 1
    assert Enum.all?(words, &(byte_size(&1) <= @max_length))
    assert Enum.all?(words, &String.match?(&1, ~r/\A=\?UTF-8\?Q\?.+\?=\z/))
  end

  # RFC 2047, section 5
  test "never splits a character across two encoded words" do
    encoded = Mail.Encoders.EncodedWord.encode(String.duplicate("очень-", 30))

    for word <- String.split(encoded, " ") do
      decoded =
        word
        |> String.replace(~r/\A=\?UTF-8\?Q\?|\?=\z/, "")
        |> String.replace("_", " ")
        |> Mail.Encoders.QuotedPrintable.decode()

      assert String.valid?(decoded)
    end
  end

  test "round-trips a long value through the parser" do
    name = "Ministerium für Wirtschaft, Tourismus, Landwirtschaft und Forsten"

    header = "Subject: " <> Mail.Encoders.EncodedWord.encode(name) <> "\r\n\r\n"

    assert %Mail.Message{headers: %{"subject" => ^name}} = Mail.Parsers.RFC2822.parse(header)
  end
end
