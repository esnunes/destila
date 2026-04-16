defmodule Destila.StringHelper do
  @moduledoc false

  def blank?(nil), do: true
  def blank?(str) when is_binary(str), do: String.trim(str) == ""
  def blank?(_), do: false
end
