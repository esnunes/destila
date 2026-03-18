defmodule DestilaWeb.SessionController do
  use DestilaWeb, :controller

  def create(conn, %{"email" => email}) do
    user = %{
      id: 1,
      name: String.split(email, "@") |> List.first() |> String.capitalize(),
      email: email,
      avatar_url: nil
    }

    conn
    |> put_session(:current_user, user)
    |> redirect(to: ~p"/")
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: ~p"/login")
  end
end
