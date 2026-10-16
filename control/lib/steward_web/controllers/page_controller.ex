defmodule StewardWeb.PageController do
  use StewardWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
