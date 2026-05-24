defmodule Symphony1.Project.SetupState do
  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, decoded}
    end
  end

  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(path, state) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(state, pretty: true),
         :ok <- File.write(path, encoded) do
      :ok
    end
  end

  @spec update(String.t(), (map() -> map())) :: :ok | {:error, term()}
  def update(path, updater) do
    with {:ok, current} <- read(path) do
      write(path, updater.(current))
    end
  end
end
