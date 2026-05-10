# frozen_string_literal: true

infusion "Ollama" do
  after :service do
    environment_variables OLLAMA_FLASH_ATTENTION: "1",
                          OLLAMA_HOST:            "0.0.0.0",
                          OLLAMA_KV_CACHE_TYPE:   "q8_0"
  end
end
