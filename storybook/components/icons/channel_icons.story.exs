defmodule Storybook.Components.Icons.ChannelIcons do
  use PhoenixStorybook.Story, :page

  def description, do: "Provider logos on channel card and preview surfaces. Use the theme switch to inspect contrast."

  @providers ~w(slack teams discord email google_drive mattermost sharepoint smtp imap telegram webhook disk ai_agents web_widget)

  def render(assigns) do
    assigns = assign(assigns, :providers, @providers)

    ~H"""
    <div class="zaq-layout-stack p-6">
      <section
        class="zaq-card-default zaq-layout-stack"
        style="background-color: var(--zaq-surface-color-base); color: var(--zaq-text-color-body-default)"
      >
        <h2 class="zaq-text-h3">Card and category preview sizes</h2>
        <div class="flex flex-wrap gap-4">
          <div :for={provider <- @providers} class="zaq-layout-stack-tight items-center w-24" data-provider={provider}>
            <div class="zaq-channel-card-icon-tile" style="background-color: var(--zaq-surface-color-raised)">
              <ZaqWeb.Components.ChannelIcons.icon provider={provider} class="zaq-icon-md" />
            </div>
            <div class="w-6 h-6 rounded-md grid place-items-center" style="background-color: var(--zaq-surface-color-elevated)">
              <ZaqWeb.Components.ChannelIcons.icon provider={provider} class="w-3.5 h-3.5" />
            </div>
            <span class="zaq-text-caption text-center break-words" style="color: var(--zaq-text-color-body-secondary)">{provider}</span>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
