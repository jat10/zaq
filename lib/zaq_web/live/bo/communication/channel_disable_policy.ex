defmodule ZaqWeb.Live.BO.Communication.ChannelDisablePolicy do
  @moduledoc "Confirmation presentation for destructive shared connector transitions."

  @doc "Requests confirmation when Channels reports logout on disable."
  @spec before_disable(map(), map(), String.t()) :: :proceed | {:confirm, String.t()}
  def before_disable(%{resolved: %{logout_on_disable: true}}, %{enabled: true}, label) do
    {:confirm,
     "Disabling #{label} will log out this profile. You will need to link it again to reconnect."}
  end

  def before_disable(_, _, _), do: :proceed
end
