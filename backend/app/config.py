"""应用配置，YAML + pydantic-settings，环境变量优先覆盖。"""

from pathlib import Path

from pydantic import BaseModel, Field
from pydantic_settings import (
    BaseSettings,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
    YamlConfigSettingsSource,
)

BASE_DIR = Path(__file__).resolve().parent.parent

_CONFIG_PATH = BASE_DIR / "config" / "config.yaml"


class VolcengineConfig(BaseModel):
    """豆包 API 凭证。"""

    app_key: str = Field(default="", description="X-Api-App-Key")
    access_key: str = Field(default="", description="X-Api-Access-Key")
    resource_id: str = Field(default="volc.seedasr.sauc.duration", description="X-Api-Resource-Id")

    @property
    def valid(self) -> bool:
        return bool(self.app_key and self.access_key and self.resource_id)


class Settings(BaseSettings):
    """应用配置，优先级：环境变量 > config.yaml > 默认值。"""

    model_config = SettingsConfigDict(extra="ignore")

    database_url: str = Field(default="sqlite:///./byvo.db")
    volcengine: VolcengineConfig = Field(default_factory=VolcengineConfig)
    sensevoice_model_dir: str = Field(default="models/sensevoice")

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        return (
            init_settings,
            env_settings,
            YamlConfigSettingsSource(settings_cls, yaml_file=_CONFIG_PATH, yaml_file_encoding="utf-8"),
        )


settings = Settings()
