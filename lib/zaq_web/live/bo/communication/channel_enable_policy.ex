defmodule ZaqWeb.Live.BO.Communication.ChannelEnablePolicy do
  @moduledoc "Adapter-specific enable-control availability for saved connectors."

  alias ZaqWeb.Live.BO.AI.BOActor

  @doc "Returns the enable restriction shared by control presentation and server-side toggle authorization."
  @spec disabled_reason(map(), map() | nil) :: String.t() | nil
  def disabled_reason(%{provider: provider, enabled: false}, current_user)
      when provider in [:whatsapp, "whatsapp"] do
    unless BOActor.super_admin?(current_user),
      do: "Only super admins can enable a WhatsApp account."
  end

  def disabled_reason(_, _), do: nil
end
