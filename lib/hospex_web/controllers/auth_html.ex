defmodule HospexWeb.AuthHTML do
  use HospexWeb, :html

  embed_templates "auth_html/*"

  @doc "Shared centered-card chrome for the login/confirm pages."
  attr :flash, :map, default: %{}
  slot :inner_block, required: true

  def auth_card(assigns) do
    ~H"""
    <div class="auth-wrap">
      <div class="auth-card">
        <div class="auth-brand">Hospex</div>
        <p :if={msg = Phoenix.Flash.get(@flash, :error)} class="auth-flash auth-flash-error">
          <%= msg %>
        </p>
        <p :if={msg = Phoenix.Flash.get(@flash, :info)} class="auth-flash auth-flash-info">
          <%= msg %>
        </p>
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    <style>
      .auth-wrap {
        min-height: 100vh; display: flex; align-items: center; justify-content: center;
        background: #f6f7f8; font-family: 'Geist', system-ui, sans-serif; color: #1b1f24;
      }
      .auth-card {
        width: 360px; background: #fff; border: 1px solid #e3e6ea; border-radius: 12px;
        padding: 32px; box-shadow: 0 1px 3px rgba(20, 24, 28, 0.06);
      }
      .auth-brand { font-size: 20px; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 18px; }
      .auth-card h1 { font-size: 16px; font-weight: 600; margin: 0 0 6px; }
      .auth-card p { font-size: 13px; line-height: 1.5; color: #5b6470; margin: 0 0 16px; }
      .auth-card label { display: block; font-size: 12px; font-weight: 500; margin-bottom: 6px; }
      .auth-card input[type="email"] {
        width: 100%; box-sizing: border-box; padding: 9px 11px; font-size: 14px;
        border: 1px solid #cfd5dc; border-radius: 8px; margin-bottom: 14px; font-family: inherit;
      }
      .auth-card input[type="email"]:focus { outline: 2px solid #2563eb33; border-color: #2563eb; }
      .auth-btn {
        width: 100%; padding: 10px 0; font-size: 14px; font-weight: 600; font-family: inherit;
        color: #fff; background: #1b1f24; border: 0; border-radius: 8px; cursor: pointer;
      }
      .auth-btn:hover { background: #2d333b; }
      .auth-flash { font-size: 13px; border-radius: 8px; padding: 10px 12px; margin-bottom: 14px; }
      .auth-flash-error { background: #fdecec; color: #9f1d1d; }
      .auth-flash-info { background: #e8f1fd; color: #1d4f9f; }
      .auth-sent { background: #eefaf0; color: #166534; border-radius: 8px; padding: 12px; font-size: 13px; line-height: 1.5; }
      .auth-again { margin-top: 14px; font-size: 12px; }
      .auth-again a { color: #2563eb; }
    </style>
    """
  end
end
