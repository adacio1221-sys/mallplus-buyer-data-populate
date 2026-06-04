"""Telegram bot that drives the /admin/populate-orders endpoint on the
MallPlus Medusa backend.

Conversational flow:
    /start                        -> greet
    /populate                     -> ask email
        <email>                   -> ask counts
            <to_pay to_ship ...>  -> call API + report
    /cancel                       -> abort the current flow

Env vars (see .env.example):
    TELEGRAM_BOT_TOKEN
    MEDUSA_BACKEND_URL            (e.g. https://staging-api.mallplus.ph)
    MEDUSA_ADMIN_EMAIL
    MEDUSA_ADMIN_PASSWORD
    ALLOWED_TELEGRAM_USER_IDS     comma-separated list, optional. If unset,
                                  any Telegram user can use the bot.
"""
from __future__ import annotations

import logging
import os
import re
import time
from dataclasses import dataclass
from typing import Optional

import httpx
from dotenv import load_dotenv
from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    ConversationHandler,
    MessageHandler,
    filters,
)

load_dotenv()

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("populator-bot")

ASK_EMAIL, ASK_COUNTS = range(2)
STATUS_KEYS = ("to_pay", "to_ship", "to_receive", "to_rate")

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


@dataclass
class Settings:
    telegram_token: str
    backend_url: str
    admin_email: str
    admin_password: str
    allowed_user_ids: Optional[set[int]]

    @classmethod
    def from_env(cls) -> "Settings":
        missing = [
            k
            for k in (
                "TELEGRAM_BOT_TOKEN",
                "MEDUSA_BACKEND_URL",
                "MEDUSA_ADMIN_EMAIL",
                "MEDUSA_ADMIN_PASSWORD",
            )
            if not os.environ.get(k)
        ]
        if missing:
            raise SystemExit(f"Missing required env vars: {', '.join(missing)}")
        raw_allowed = os.environ.get("ALLOWED_TELEGRAM_USER_IDS", "").strip()
        allowed: Optional[set[int]] = None
        if raw_allowed:
            allowed = {int(x) for x in raw_allowed.split(",") if x.strip()}
        return cls(
            telegram_token=os.environ["TELEGRAM_BOT_TOKEN"],
            backend_url=os.environ["MEDUSA_BACKEND_URL"].rstrip("/"),
            admin_email=os.environ["MEDUSA_ADMIN_EMAIL"],
            admin_password=os.environ["MEDUSA_ADMIN_PASSWORD"],
            allowed_user_ids=allowed,
        )


class MedusaAdminClient:
    """Tiny client that handles /auth/user/emailpass and a 5-minute token cache."""

    def __init__(self, settings: Settings):
        self._settings = settings
        self._token: Optional[str] = None
        self._token_exp: float = 0.0

    async def _get_token(self, http: httpx.AsyncClient) -> str:
        if self._token and time.time() < self._token_exp - 30:
            return self._token
        r = await http.post(
            f"{self._settings.backend_url}/auth/user/emailpass",
            json={
                "email": self._settings.admin_email,
                "password": self._settings.admin_password,
            },
        )
        r.raise_for_status()
        token = r.json().get("token")
        if not token:
            raise RuntimeError(f"Admin login returned no token: {r.text}")
        self._token = token
        # Medusa admin tokens default to 1h; refresh just inside that.
        self._token_exp = time.time() + 50 * 60
        return token

    async def populate(self, email: str, counts: dict[str, int]) -> dict:
        async with httpx.AsyncClient(timeout=120.0) as http:
            token = await self._get_token(http)
            r = await http.post(
                f"{self._settings.backend_url}/admin/populate-orders",
                json={"customer_email": email, "counts": counts},
                headers={"Authorization": f"Bearer {token}"},
            )
            if r.status_code >= 400 and r.status_code != 207:
                raise RuntimeError(
                    f"Admin API {r.status_code}: {r.text[:500]}"
                )
            return r.json()


def _is_allowed(settings: Settings, update: Update) -> bool:
    if settings.allowed_user_ids is None:
        return True
    if update.effective_user is None:
        return False
    return update.effective_user.id in settings.allowed_user_ids


def _gate(settings: Settings):
    async def check(update: Update, context: ContextTypes.DEFAULT_TYPE) -> bool:
        if _is_allowed(settings, update):
            return True
        if update.effective_message:
            await update.effective_message.reply_text(
                "Not authorized. Ask the bot owner to add your Telegram ID."
            )
        return False

    return check


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await context.bot_data["gate"](update, context):
        return
    await update.message.reply_text(
        "MallPlus order populator.\n"
        "Use /populate to create test orders in each buyer-tab status.\n"
        "Use /cancel to abort an in-progress flow."
    )


async def cmd_populate(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await context.bot_data["gate"](update, context):
        return ConversationHandler.END
    await update.message.reply_text(
        "Buyer email to populate orders for? (e.g. qa+adacio@example.com)"
    )
    return ASK_EMAIL


async def on_email(update: Update, context: ContextTypes.DEFAULT_TYPE):
    email = (update.message.text or "").strip()
    if not EMAIL_RE.match(email):
        await update.message.reply_text(
            "That doesn't look like an email. Try again, or /cancel."
        )
        return ASK_EMAIL
    context.user_data["email"] = email
    await update.message.reply_text(
        "Counts? Send 4 numbers separated by spaces:\n"
        "  TO_PAY TO_SHIP TO_RECEIVE TO_RATE\n"
        "Example: 2 1 1 1"
    )
    return ASK_COUNTS


async def on_counts(update: Update, context: ContextTypes.DEFAULT_TYPE):
    parts = (update.message.text or "").split()
    if len(parts) != 4:
        await update.message.reply_text(
            "Need exactly 4 numbers (TO_PAY TO_SHIP TO_RECEIVE TO_RATE)."
        )
        return ASK_COUNTS
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        await update.message.reply_text("Each value must be an integer.")
        return ASK_COUNTS
    if any(n < 0 for n in nums) or sum(nums) == 0:
        await update.message.reply_text(
            "All values must be >= 0 and the total must be at least 1."
        )
        return ASK_COUNTS
    if sum(nums) > 50:
        await update.message.reply_text(
            "Total exceeds the per-request cap of 50. Try smaller numbers."
        )
        return ASK_COUNTS

    counts = dict(zip(STATUS_KEYS, nums))
    email = context.user_data["email"]
    await update.message.reply_text(
        f"Populating {sum(nums)} orders for {email}... this can take a moment."
    )

    client: MedusaAdminClient = context.bot_data["client"]
    try:
        result = await client.populate(email, counts)
    except Exception as e:
        log.exception("populate failed")
        await update.message.reply_text(f"Failed: {e}")
        return ConversationHandler.END

    lines = [f"Done for {email}:"]
    for k in STATUS_KEYS:
        ids = result.get(k) or []
        lines.append(f"  {k}: {len(ids)} created")
        for oid in ids:
            lines.append(f"    - {oid}")
    errors = result.get("errors") or []
    if errors:
        lines.append(f"errors ({len(errors)}):")
        for e in errors:
            lines.append(f"  - {e.get('status')} #{e.get('index')}: {e.get('message')}")
    await update.message.reply_text("\n".join(lines))
    return ConversationHandler.END


async def cmd_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    context.user_data.clear()
    await update.message.reply_text("Cancelled.")
    return ConversationHandler.END


def main() -> None:
    settings = Settings.from_env()
    client = MedusaAdminClient(settings)

    app = Application.builder().token(settings.telegram_token).build()
    app.bot_data["client"] = client
    app.bot_data["gate"] = _gate(settings)

    conv = ConversationHandler(
        entry_points=[CommandHandler("populate", cmd_populate)],
        states={
            ASK_EMAIL: [MessageHandler(filters.TEXT & ~filters.COMMAND, on_email)],
            ASK_COUNTS: [MessageHandler(filters.TEXT & ~filters.COMMAND, on_counts)],
        },
        fallbacks=[CommandHandler("cancel", cmd_cancel)],
    )

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(conv)
    app.add_handler(CommandHandler("cancel", cmd_cancel))

    log.info("Bot starting (polling)...")
    app.run_polling()


if __name__ == "__main__":
    main()
