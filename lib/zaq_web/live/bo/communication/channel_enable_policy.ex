defmodule ZaqWeb.Live.BO.Communication.ChannelEnablePolicy do
  @moduledoc "Adapter-specific enable-control availability and presentation for saved connectors."

  alias ZaqWeb.Live.BO.AI.BOActor

  @doc "Returns the enable-control restriction for presentation; Engine enforces authorization."
  @spec disabled_reason(map(), map() | nil) :: String.t() | nil
  def disabled_reason(%{provider: provider, enabled: false}, current_user)
      when provider in [:whatsapp, "whatsapp"] do
    unless BOActor.super_admin?(current_user),
      do: "Only super admins can enable a WhatsApp account."
  end

  def disabled_reason(_, _), do: nil

  @doc "Opens the saved WhatsApp profile's connection flow after successful enablement."
  @spec after_enable(atom() | String.t(), map()) :: :proceed | :open_connection
  def after_enable(provider, %{enabled: true}) when provider in [:whatsapp, "whatsapp"],
    do: :open_connection

  def after_enable(_, _), do: :proceed
end
