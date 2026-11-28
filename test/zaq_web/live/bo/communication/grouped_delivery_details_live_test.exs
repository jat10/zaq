defmodule ZaqWeb.Live.BO.Communication.GroupedDeliveryDetailsLiveTest do
  use ZaqWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.ChannelDeliveryFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Conversations.{Message, MessageDelivery, TranscriptMessage}
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Repo

  setup %{conn: conn} do
    admin = super_admin_fixture()
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
    ctx = stored_channel_answer()
    Map.merge(ctx, %{admin: admin, conn: init_test_session(conn, %{user_id: admin.id})})
  end

  test "a confirmed message opens all unsuccessful parts in one modal and keeps normal message actions",
       ctx do
    confirm(ctx)
    record(ctx)
    {:ok, view, html} = live(ctx.conn, path(ctx))
    assert bubble_count(html, ctx) == 1
    assert has_element?(view, "#history-message-#{ctx.answer.id} [data-delivery-state='partial']")
    refute has_element?(view, "#history-message-#{ctx.answer.id} .zaq-chat-delivery")
    assert has_element?(view, "#history-message-#{ctx.answer.id} [phx-click='feedback']")
    assert has_element?(view, "#history-message-#{ctx.answer.id} [phx-click='open_message_info']")
    open(view, ctx)
    assert part_count(view) == 3
    assert has_element?(view, "#channel-delivery-details", "Rejected")
    assert has_element?(view, "#channel-delivery-details", "Unconfirmed")
    assert has_element?(view, "#channel-delivery-details", "may have accepted")
    refute render(view) =~ "PRIVATE_PROVIDER_ERROR"

    view
    |> element("#channel-delivery-details button[phx-click='close_delivery_info']", "Close")
    |> render_click()

    refute has_element?(view, "#channel-delivery-details")
    open(view, ctx)
    assert part_count(view) == 3
    assert bubble_count(render(view), ctx) == 1
  end

  test "open grouped details survive confirmation and refresh without becoming a second bubble",
       ctx do
    record(ctx)
    {:ok, view, _} = live(ctx.conn, path(ctx))
    open(view, ctx)
    assert part_count(view) == 3
    confirm(ctx)
    refresh(view, ctx)
    assert has_element?(view, "#channel-delivery-details", "Partially delivered")
    assert part_count(view) == 3
    assert bubble_count(render(view), ctx) == 1
    record(ctx, 1)
    refresh(view, ctx)
    assert part_count(view) == 1
    {:ok, reopened, _} = live(ctx.conn, path(ctx))
    open(reopened, ctx)
    assert part_count(reopened) == 1
  end

  test "stale and deleted message IDs never open global delivery information", ctx do
    confirm(ctx)
    record(ctx)
    {:ok, view, _} = live(ctx.conn, path(ctx))
    render_hook(view, "open_delivery_info", %{"id" => Ecto.UUID.generate()})
    refute has_element?(view, "#channel-delivery-details")

    Repo.delete_all(
      from placement in TranscriptMessage, where: placement.message_id == ^ctx.answer.id
    )

    Repo.delete!(Repo.get!(Message, ctx.answer.id))
    render_hook(view, "open_delivery_info", %{"id" => ctx.answer.id})
    refute has_element?(view, "#channel-delivery-details")
  end

  test "a fresh delivery-details read rechecks authorization after role revocation", ctx do
    confirm(ctx)
    record(ctx)
    {:ok, view, _} = live(ctx.conn, path(ctx))
    open(view, ctx)
    staff = user_fixture()
    ctx.admin |> Ecto.Changeset.change(role_id: staff.role_id) |> Repo.update!()
    render_hook(view, "open_delivery_info", %{"id" => ctx.answer.id})
    assert render(view) =~ "Not authorized"
    refute has_element?(view, "#channel-delivery-details")
    refute has_element?(view, "[id^='history-message-']")
  end

  defp record(ctx, count \\ 3) do
    parts = [
      %{
        step_id: [:send, 0],
        group_id: 0,
        operation: :send,
        stage: :publication,
        outcome: :failed,
        reason: :rejected,
        attachment_refs: [0],
        omitted_attachment_count: 0
      },
      %{
        step_id: [:upload, 1, 0],
        group_id: 1,
        operation: :upload,
        stage: :upload,
        outcome: :unconfirmed,
        reason: :timeout,
        attachment_refs: [1],
        omitted_attachment_count: 0
      },
      %{
        step_id: nil,
        group_id: 2,
        operation: :prepare,
        stage: :preparation,
        outcome: :failed,
        reason: :size_limit,
        attachment_refs: [2],
        omitted_attachment_count: 0
      }
    ]

    assert {:ok, :recorded} =
             MessageDelivery.record(%{
               user_message_id: ctx.input.id,
               assistant_message_id: ctx.answer.id,
               channel_config_id: ctx.config.id,
               delivery_parts: %{
                 version: 1,
                 attempt_id: Ecto.UUID.generate(),
                 parts: Enum.take(parts, count),
                 confirmed_message_count: 1,
                 confirmed_attachment_count: 0,
                 omitted_part_count: 0,
                 cause: "PRIVATE_PROVIDER_ERROR"
               }
             })
  end

  defp confirm(ctx) do
    assert {:ok, _} =
             HistoryIngress.capture_confirmed(%{
               confirmation: :confirmed,
               kind: :channel,
               provider: ctx.config.provider,
               channel_config_id: ctx.config.id,
               channel_id: "room",
               message_id: "provider-#{ctx.answer.id}",
               user_message_id: ctx.input.id,
               assistant_message_id: ctx.answer.id
             })
  end

  defp open(view, ctx),
    do:
      view
      |> element("#history-message-#{ctx.answer.id} [data-testid='delivery-status']")
      |> render_click()

  defp refresh(view, ctx) do
    send(view.pid, {:channel_history_updated, ctx.captured.transcript_id, [ctx.answer.id]})
    send(view.pid, :flush_history_updates)
    render(view)
  end

  defp bubble_count(html, ctx),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#history-message-#{ctx.answer.id}")
      |> Enum.count()

  defp part_count(view),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#channel-delivery-details [data-testid='delivery-failed-part']")
      |> Enum.count()

  defp path(ctx), do: ~p"/bo/channels/history/#{ctx.captured.transcript_id}"
end
