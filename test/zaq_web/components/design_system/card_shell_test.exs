defmodule ZaqWeb.Components.DesignSystem.CardShellTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.CardShell

  test "card_shell/1 renders muted surface without hover class" do
    html =
      render_component(&CardShell.card_shell/1,
        id: "muted-card",
        variant: :muted,
        as: :div
      ) do
        "Body"
      end

    assert html =~ "id=\"muted-card\""
    assert html =~ "zaq-card-default"
    refute html =~ "zaq-card-hover"
    refute html =~ "href="
  end

  test "card_shell/1 wraps interactive card with link and hover surface" do
    html =
      render_component(&CardShell.card_shell/1,
        id: "linked-card",
        primary_link: %{destination: "/bo/channels"}
      ) do
        "Tile"
      end

    assert html =~ ~s(href="/bo/channels")
    assert html =~ "zaq-card-hover"
    assert html =~ "id=\"linked-card\""
  end

  test "card_shell/1 renders footer ghost button with split primary link" do
    html =
      render_component(&CardShell.card_shell/1,
        id: "provider-card",
        primary_link: %{destination: "/bo/channels/retrieval/slack"},
        footer_link: %{
          id: "provider-card-configure",
          label: "Configure",
          destination: "/bo/channels/retrieval/slack"
        }
      ) do
        "Slack"
      end

    assert html =~ ~s(href="/bo/channels/retrieval/slack")
    assert html =~ "id=\"provider-card-configure\""
    assert html =~ "Configure"
    assert html =~ "zaq-btn"
  end

  test "card_shell/1 renders secondary link below card" do
    html =
      render_component(&CardShell.card_shell/1,
        id: "metric-shell",
        primary_link: %{id: "metric-link", destination: "/bo/ingestion"},
        secondary_link: %{
          id: "metric-secondary",
          destination: "/bo/dashboard",
          label: "View dashboard"
        }
      ) do
        "128"
      end

    assert html =~ "space-y-2"
    assert html =~ "id=\"metric-secondary\""
    assert html =~ "View dashboard"
  end
end
