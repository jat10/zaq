defmodule ZaqWeb.Components.DesignSystem.ChannelConnectorCard do
  @moduledoc """
  Connector settings bar shared by channel configuration pages.

  The parent LiveView owns selection and action events. Configure the common edit
  and enable/disable controls with their existing IDs and events. Provider-specific
  controls belong in `:actions`.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  alias ZaqWeb.Components.DesignSystem.Button

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :provider, :string, required: true
  attr :url, :string, default: nil
  attr :enabled, :boolean, default: false
  attr :enabled_label, :string, default: "Active"
  attr :selected, :boolean, default: false
  attr :select_event, :string, default: nil
  attr :connector_id, :integer, default: nil
  attr :icon, :string, default: nil
  attr :toggle_event, :string, default: nil
  attr :toggle_button_id, :string, default: nil
  attr :toggle_disabled, :boolean, default: false
  attr :toggle_disabled_reason, :string, default: nil
  attr :edit_event, :string, default: nil
  attr :edit_button_id, :string, default: nil
  attr :edit_action, :string, default: nil

  slot :status
  slot :detail
  slot :actions

  def channel_connector_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="zaq-card-default zaq-card-hover zaq-border-default flex flex-wrap items-center justify-between"
      style={if(@selected, do: "border-color: var(--zaq-border-color-accent)")}
    >
      <div class="flex items-center gap-4">
        <div
          class="w-10 h-10 rounded-xl grid place-items-center"
          style={
            if(@enabled,
              do:
                "background-color: var(--zaq-surface-color-accent); color: var(--zaq-icon-color-accent)",
              else:
                "background-color: var(--zaq-surface-color-elevated); color: var(--zaq-icon-color-default)"
            )
          }
        >
          <.icon :if={@icon} name={@icon} class="zaq-icon-md" />
          <svg
            :if={!@icon}
            class="zaq-icon-md"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            viewBox="0 0 24 24"
            aria-hidden="true"
          >
            <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
          </svg>
        </div>
        <div>
          <div class="flex items-center gap-2 mb-1">
            <button
              :if={@select_event}
              type="button"
              phx-click={@select_event}
              phx-value-id={@connector_id}
              aria-current={if(@selected, do: "true", else: nil)}
              class="zaq-text-h4 zaq-focus-visible"
              style="color: var(--zaq-text-color-body-default)"
            >
              {@name}
            </button>
            <p
              :if={!@select_event}
              class="zaq-text-h4"
              style="color: var(--zaq-text-color-body-default)"
            >
              {@name}
            </p>
            {render_slot(@status)}
            <span class={[
              "zaq-pill zaq-text-caption uppercase tracking-wider",
              if(@enabled and @enabled_label == "Active",
                do: "zaq-pill--success",
                else: "zaq-pill--elevated"
              )
            ]}>
              {if @enabled, do: @enabled_label, else: "Disabled"}
            </span>
          </div>
          <div class="flex items-center gap-3">
            <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
              {@provider}
            </p>
            <span :if={@url} style="color: var(--zaq-text-color-body-tertiary)">·</span>
            <p
              :if={@url}
              class="zaq-text-body-sm truncate max-w-[280px]"
              style="color: var(--zaq-text-color-body-tertiary)"
            >
              {@url}
            </p>
          </div>
          {render_slot(@detail)}
        </div>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <Button.button
          :if={@toggle_event}
          id={@toggle_button_id || "toggle-#{@id}"}
          variant={:secondary}
          phx-click={@toggle_event}
          phx-value-id={@connector_id}
          disabled={@toggle_disabled}
          title={@toggle_disabled_reason}
        >{if @enabled, do: "Disable", else: "Enable"}</Button.button>
        <Button.button
          :if={@edit_event}
          id={@edit_button_id || "edit-#{@id}"}
          variant={:tertiary}
          icon="hero-pencil-square"
          icon_only
          aria-label="Edit"
          title="Edit"
          phx-click={@edit_event}
          phx-value-id={@connector_id}
          phx-value-action={@edit_action}
        />
        {render_slot(@actions)}
      </div>
    </div>
    """
  end
end
