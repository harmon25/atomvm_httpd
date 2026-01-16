defmodule JsonEncoderTest do
  use ExUnit.Case

  @moduletag :json_encoder

  test "encode boolean true" do
    assert encode_to_binary(true) == "true"
  end

  test "encode boolean false" do
    assert encode_to_binary(false) == "false"
  end

  test "encode null values" do
    assert encode_to_binary(nil) == "nil"
    assert encode_to_binary(:null) == "null"
    assert encode_to_binary(:undefined) == "null"
  end

  test "encode atom" do
    assert encode_to_binary(:foo) == ~S("foo")
  end

  test "encode binary string" do
    assert encode_to_binary("bar") == ~S("bar")
  end

  test "encode integer" do
    assert encode_to_binary(42) == "42"
  end

  test "encode float" do
    assert encode_to_binary(3.14) |> String.starts_with?("3.14")
  end

  test "encode list of integers (array)" do
    assert encode_to_binary([1, 2, 3]) == "[1,2,3]"
  end

  test "encode map" do
    result = encode_to_binary(%{foo: "bar", baz: 42})
    assert result =~ ~S({"foo": "bar", "baz": 42})
  end

  test "encode nested map" do
    result = encode_to_binary(%{foo: %{bar: 1, baz: [2, 3]}})
    # Accept any key order in nested map
    assert result in  [~S({"foo": {"bar": 1,"baz": [2,3]}}), ~S({"foo": {"baz": [2,3], "bar": 1}})]
  end

  test "encode deeply nested list" do
    result = encode_to_binary([1, [2, [3, %{a: "b"}]]])
    assert result =~ ~S([1,[2,[3,{"a": "b"}]]])
  end

  defp encode_to_binary(val) do
    case :json_encoder.encode(val) do
      v when is_list(v) -> :erlang.iolist_to_binary(v)
      v -> v
    end
  end
end
