defmodule OccLedger.Application do
  use Application

  def start(_type, _args) do
    children = [
      OccLedger.Repo,
      OccLedger.DBWriter,
      OccLedger.BatchCoordinator
    ]

    opts = [strategy: :one_for_one, name: OccLedger.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
