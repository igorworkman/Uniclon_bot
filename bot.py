import asyncio
from uniclon.bot import run_polling

if __name__ == "__main__":
    try:
        asyncio.run(run_polling())
    except (KeyboardInterrupt, SystemExit):
        pass
