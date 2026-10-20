#!/usr/bin/env python3
"""Write an OpenHands CLI agent config with prompt caching disabled.

The CLI's --override-with-envs option does not expose the SDK's
caching_prompt setting, so this config is written before headless CLI startup.
"""
import os
from pathlib import Path

from openhands.sdk import Agent, LLM
from openhands_cli.utils import get_default_cli_agent


def main() -> None:
    api_key = os.environ["LLM_API_KEY"]
    model = os.environ.get("LLM_MODEL", "gemini/gemini-3.5-flash-lite")
    persistence_dir = Path(os.environ["OPENHANDS_PERSISTENCE_DIR"])

    llm = LLM(
        model=model,
        api_key=api_key,
        usage_id="agent",
        caching_prompt=False,
    )
    agent = get_default_cli_agent(llm)
    agent = agent.model_copy(
        update={
            "llm": agent.llm.model_copy(update={"caching_prompt": False}),
            "condenser": agent.condenser.model_copy(
                update={
                    "llm": agent.condenser.llm.model_copy(
                        update={"caching_prompt": False}
                    )
                }
            ),
        }
    )

    serialized_agent = agent.model_dump_json(context={"expose_secrets": True})
    verified_agent = Agent.model_validate_json(serialized_agent)
    assert not verified_agent.llm.caching_prompt
    assert verified_agent.condenser is not None
    assert not verified_agent.condenser.llm.caching_prompt

    persistence_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    settings_path = persistence_dir / "agent_settings.json"
    settings_path.write_text(serialized_agent, encoding="utf-8")
    settings_path.chmod(0o600)

    persisted_agent = Agent.model_validate_json(settings_path.read_text(encoding="utf-8"))
    assert not persisted_agent.llm.caching_prompt
    assert persisted_agent.condenser is not None
    assert not persisted_agent.condenser.llm.caching_prompt
    print("Verified prompt caching is disabled for agent and condenser.")


if __name__ == "__main__":
    main()
