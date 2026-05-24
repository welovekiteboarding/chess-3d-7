defmodule Symphony1.Project.SetupIntent do
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, decoded}
    end
  end
end
