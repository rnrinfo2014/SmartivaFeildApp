"""Private dependency checks; public health responses never expose credentials."""
import os
from pathlib import Path
import tempfile

from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError

from . import models


def deployment_ready(settings, engine) -> bool:
    # FieldOps requires Groq for voice even with Gemini text extraction.
    if engine is None or not settings.groq_api_key:
        return False
    if settings.ai_provider == 'gemini' and not settings.gemini_api_key:
        return False
    try:
        with engine.connect() as connection:
            # Validate schema/columns as well as connectivity, without reading data.
            for table in models.Base.metadata.sorted_tables:
                if table.name not in {'sync_outbox', 'sync_cursors'}:
                    connection.execute(select(table).limit(0))
        directory = Path(settings.audio_storage_path)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with tempfile.TemporaryFile(dir=directory) as probe:
            probe.write(b'fieldops-readiness')
            probe.flush()
            os.fsync(probe.fileno())
        return True
    except (SQLAlchemyError, OSError):
        return False
