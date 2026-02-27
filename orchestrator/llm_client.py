"""Ollama LLM client for orchestrator decisions."""

import requests
import json
import logging
import re

logger = logging.getLogger(__name__)


class OllamaClient:
    def __init__(self, base_url="http://localhost:11434", model="qwen3:8b", disable_thinking=False):
        self.base_url = base_url
        self.model = model
        self.disable_thinking = disable_thinking

    def decide(self, context: str) -> dict:
        """Ask the LLM to make a routing decision.

        Returns dict with:
          - action: "send_to_writer" | "send_to_executor" | "next_task" | "flag_human" | "done"
          - message: str to send to the target agent
          - reasoning: str explaining the decision
        """
        system_prompt = """You are an AI project manager orchestrating a BDD E2E testing pipeline with 2 agents: Writer and Executor.

ALWAYS respond with valid JSON only (no markdown, no backticks):
{
  "action": "send_to_writer" | "send_to_executor" | "next_task" | "flag_human" | "done",
  "message": "instruction to send to the agent",
  "reasoning": "brief explanation of your decision"
}

BDD Pipeline Rules:
- Tasks START with Writer: Writer creates .feature files + step definitions + Page Objects
- Writer produced feature files -> action = "send_to_executor" (forward to Executor)
- Executor ran tests and they pass -> action = "next_task"
- Executor reports test failures -> action = "send_to_writer" (Writer must fix)
- If same task failed 5+ times: action = "flag_human"
- If no more tasks: action = "done"
- Keep messages clear and actionable
- Do NOT include thinking tags or markdown formatting"""

        try:
            # Qwen3: append /no_think to suppress thinking tags in output
            prompt = context
            if self.disable_thinking:
                prompt = context + " /no_think"

            response = requests.post(
                f"{self.base_url}/api/generate",
                json={
                    "model": self.model,
                    "prompt": prompt,
                    "system": system_prompt,
                    "stream": False,
                    "options": {
                        "temperature": 0.3,
                        "num_predict": 4096,
                    },
                },
                timeout=60,
            )
            response.raise_for_status()
            result = response.json()
            raw_text = result.get("response", "")

            # Strip thinking tags if present (Qwen3 sometimes adds them)
            raw_text = re.sub(r"<think>.*?</think>", "", raw_text, flags=re.DOTALL)
            raw_text = raw_text.strip()

            # Handle markdown code blocks
            if "```json" in raw_text:
                raw_text = raw_text.split("```json")[1].split("```")[0].strip()
            elif "```" in raw_text:
                raw_text = raw_text.split("```")[1].split("```")[0].strip()

            decision = json.loads(raw_text)
            logger.info(
                f"LLM decision: {decision.get('action')} - {decision.get('reasoning')}"
            )
            return decision

        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse LLM response: {raw_text[:200]}")
            return {
                "action": "flag_human",
                "message": f"Orchestrator couldn't parse LLM response: {str(e)}",
                "reasoning": "JSON parse failure",
            }
        except requests.RequestException as e:
            logger.error(f"Ollama request failed: {e}")
            return {
                "action": "flag_human",
                "message": f"Orchestrator LLM is unreachable: {str(e)}",
                "reasoning": "Ollama connection failure",
            }

    def decide_with_system(self, system_prompt: str, context: str) -> dict:
        """Like decide() but with a custom system prompt."""
        try:
            prompt = context
            if self.disable_thinking:
                prompt = context + " /no_think"

            response = requests.post(
                f"{self.base_url}/api/generate",
                json={
                    "model": self.model,
                    "prompt": prompt,
                    "system": system_prompt,
                    "stream": False,
                    "options": {
                        "temperature": 0.3,
                        "num_predict": 4096,
                    },
                },
                timeout=60,
            )
            response.raise_for_status()
            result = response.json()
            raw_text = result.get("response", "")

            raw_text = re.sub(r"<think>.*?</think>", "", raw_text, flags=re.DOTALL)
            raw_text = raw_text.strip()

            if "```json" in raw_text:
                raw_text = raw_text.split("```json")[1].split("```")[0].strip()
            elif "```" in raw_text:
                raw_text = raw_text.split("```")[1].split("```")[0].strip()

            return json.loads(raw_text)

        except (json.JSONDecodeError, requests.RequestException) as e:
            logger.error(f"LLM interpret failed: {e}")
            return {"action": "reply", "text": "Sorry, I couldn't process that. Try a direct command or type 'help'."}

    def health_check(self) -> bool:
        """Check if Ollama is running and model is available."""
        try:
            r = requests.get(f"{self.base_url}/api/tags", timeout=5)
            r.raise_for_status()
            models = [m["name"] for m in r.json().get("models", [])]
            available = any(self.model.split(":")[0] in m for m in models)
            if not available:
                logger.warning(
                    f"Model {self.model} not found. Available: {models}"
                )
            return available
        except Exception as e:
            logger.error(f"Ollama health check failed: {e}")
            return False
