import asyncio
# REGION AI: imports
from uniclon_bot import run_polling
# END REGION AI

if __name__ == "__main__":
    try:
        asyncio.run(run_polling())
    except (KeyboardInterrupt, SystemExit):
        pass
