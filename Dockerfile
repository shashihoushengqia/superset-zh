# 构建翻译文件(请勿替换FROM)
FROM python:3.12.6-slim-bookworm AS builder
COPY . /app
WORKDIR /app
RUN pip install --no-cache-dir --upgrade pip &&\
    pip install --no-cache-dir -r requirements.txt &&\
    python generate_locales.py && python generate_messages.py

# 将翻译导入镜像(此处替换所需的官方版本)
FROM apache/superset:6.1.0
COPY --from=builder /app/messages.json /app/superset/translations/zh/LC_MESSAGES/messages.json
COPY --from=builder /app/target/messages.mo /app/superset/translations/zh/LC_MESSAGES/messages.mo
USER root

RUN sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources \
    && sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gcc libpq-dev python3-dev pkg-config \
        libmariadb-dev-compat libmariadb-dev build-essential git \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
ENV UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
RUN uv pip install --no-cache psycopg2-binary==2.9.12 python-ldap==3.4.7 mysqlclient==2.2.8 \
    trino==0.337.0 chardet==7.4.3

RUN sed -i 's/READ_CHUNK_SIZE = 1000/READ_CHUNK_SIZE = 20000/' \
    /app/superset/commands/database/uploaders/base.py

RUN python3 << 'PATCH_EOF'
import re

# Patch 1: csv_reader.py - CSV 解析性能优化
filepath = "/app/superset/commands/database/uploaders/csv_reader.py"
with open(filepath, "r") as f:
    code = f.read()

code = code.replace(
    "from importlib import util",
    "from functools import lru_cache\nfrom importlib import util"
)

old_detect = '''    @staticmethod
    def _detect_encoding(file: FileStorage) -> str:
        """Detect file encoding with progressive sampling"""
        # Try progressively larger samples to improve detection reliability
        sample_sizes = [1024, 8192, 32768, 65536]

        for sample_size in sample_sizes:
            file.seek(0)
            sample = file.read(sample_size)
            if not sample:  # Empty file or reached end
                break

            for encoding in ENCODING_FALLBACKS:
                try:
                    sample.decode(encoding)
                    file.seek(0)
                    return encoding
                except UnicodeDecodeError:
                    continue

        file.seek(0)
        return DEFAULT_ENCODING'''

new_detect = '''    @staticmethod
    def _detect_encoding(file: FileStorage) -> str:
        """Detect file encoding with chardet one-shot, fallback to progressive sampling"""
        file.seek(0)
        sample = file.read(65536)
        file.seek(0)

        if not sample:
            return DEFAULT_ENCODING

        try:
            import chardet
            result = chardet.detect(sample)
            encoding = result.get("encoding")
            if encoding:
                return encoding
        except ImportError:
            pass

        for encoding in ENCODING_FALLBACKS:
            try:
                sample.decode(encoding)
                return encoding
            except UnicodeDecodeError:
                continue

        return DEFAULT_ENCODING'''

code = code.replace(old_detect, new_detect)

old_engine = '''    @staticmethod
    def _select_optimal_engine() -> str:
        """Select the best available CSV parsing engine"""
        try:
            # Check if pyarrow is available as a separate package
            pyarrow_spec = util.find_spec("pyarrow")
            if not pyarrow_spec:
                return "c"

            # Import pyarrow to verify it works properly
            import pyarrow as pa  # noqa: F401

            # Check if pandas has built-in pyarrow support
            pandas_version = str(pd.__version__)
            has_builtin_pyarrow = "pyarrow" in pandas_version

            if has_builtin_pyarrow:
                # Pandas has built-in pyarrow, safer to use c engine
                logger.info("Pandas has built-in pyarrow support, using 'c' engine")
                return "c"
            else:
                # External pyarrow available, can safely use it
                logger.info("Using 'pyarrow' engine for CSV parsing")
                return "pyarrow"

        except ImportError:
            # PyArrow import failed, fall back to c engine
            logger.info("PyArrow not properly installed, falling back to 'c' engine")
            return "c"
        except Exception as ex:
            # Any other error, fall back to c engine
            logger.warning(
                "Error selecting CSV engine: %s, falling back to 'c' engine", ex
            )
            return "c"'''

new_engine = '''    @staticmethod
    @lru_cache(maxsize=1)
    def _select_optimal_engine() -> str:
        """Select the best available CSV parsing engine (cached)"""
        try:
            import pyarrow as pa  # noqa: F401
            logger.info("Using 'pyarrow' engine for CSV parsing")
            return "pyarrow"
        except ImportError:
            logger.info("PyArrow not available, falling back to 'c' engine")
            return "c"
        except Exception as ex:
            logger.warning(
                "Error selecting CSV engine: %s, falling back to 'c' engine", ex
            )
            return "c"'''

code = code.replace(old_engine, new_engine)

old_non_numeric = '''    @staticmethod
    def _find_invalid_values_non_numeric(
        df: pd.DataFrame, column: str, dtype: str
    ) -> pd.Series:
        """
        Find invalid values for non-numeric type conversion.

        Identifies rows where values cannot be converted to the specified non-numeric
        data type by attempting conversion and catching exceptions. This is used for
        string, categorical, or other non-numeric type conversions.

        :param df: DataFrame containing the data
        :param column: Name of the column to check for invalid values
        :param dtype: Target data type for conversion (e.g., 'string', 'category')

        :return: Boolean Series indicating which rows have
        invalid values for the target type
        """
        invalid_mask = pd.Series([False] * len(df), index=df.index)
        for idx, value in df[column].items():
            if pd.notna(value):
                try:
                    pd.Series([value]).astype(dtype)
                except (ValueError, TypeError):
                    invalid_mask[idx] = True
        return invalid_mask'''

new_non_numeric = '''    @staticmethod
    def _find_invalid_values_non_numeric(
        df: pd.DataFrame, column: str, dtype: str
    ) -> pd.Series:
        """
        Find invalid values for non-numeric type conversion.

        Identifies rows where values cannot be converted to the specified non-numeric
        data type by attempting conversion and catching exceptions. This is used for
        string, categorical, or other non-numeric type conversions.

        :param df: DataFrame containing the data
        :param column: Name of the column to check for invalid values
        :param dtype: Target data type for conversion (e.g., 'string', 'category')

        :return: Boolean Series indicating which rows have
        invalid values for the target type
        """
        try:
            df[column].astype(dtype)
            return pd.Series(False, index=df.index)
        except (ValueError, TypeError):
            converted = df[column].astype(dtype, errors="coerce")
            return converted.isna() & df[column].notna()'''

code = code.replace(old_non_numeric, new_non_numeric)

old_cast = '''        numeric_types = {"int64", "int32", "float64", "float32"}

        try:
            if dtype in numeric_types:
                df[column] = pd.to_numeric(df[column], errors="raise")
                df[column] = df[column].astype(dtype)'''

new_cast = '''        if df[column].dtype.name == dtype:
            return

        numeric_types = {"int64", "int32", "float64", "float32"}

        try:
            if dtype in numeric_types:
                df[column] = pd.to_numeric(df[column], errors="raise")
                if df[column].dtype.name != dtype:
                    df[column] = df[column].astype(dtype)'''

code = code.replace(old_cast, new_cast)

with open(filepath, "w") as f:
    f.write(code)

print("csv_reader.py patch applied")

# Patch 2: base.py - 并行写入
filepath2 = "/app/superset/commands/database/uploaders/base.py"
with open(filepath2, "r") as f:
    code2 = f.read()

code2 = code2.replace(
    "from functools import partial",
    "from functools import partial\nfrom concurrent.futures import ThreadPoolExecutor, as_completed"
)

old_method = '''    def _dataframe_to_database(
        self,
        df: pd.DataFrame,
        database: Database,
        table_name: str,
        schema_name: Optional[str],
    ) -> None:
        """
        Upload DataFrame to database

        :param df:
        :throws DatabaseUploadFailed: if there is an error uploading the DataFrame
        """
        try:
            data_table = Table(table=table_name, schema=schema_name)
            to_sql_kwargs = {
                "chunksize": READ_CHUNK_SIZE,
                "if_exists": self._options.get("already_exists", "fail"),
                "index": self._options.get("dataframe_index", False),
            }
            if self._options.get("index_label") and self._options.get(
                "dataframe_index"
            ):
                to_sql_kwargs["index_label"] = self._options.get("index_label")
            database.db_engine_spec.df_to_sql(
                database,
                data_table,
                df,
                to_sql_kwargs=to_sql_kwargs,
            )
        except ValueError as ex:
            raise DatabaseUploadFailed(
                message=_(
                    "Table already exists. You can change your "
                    "'if table already exists' strategy to append or "
                    "replace or provide a different Table Name to use."
                )
            ) from ex
        except Exception as ex:
            message = ex.message if hasattr(ex, "message") and ex.message else str(ex)
            raise DatabaseUploadFailed(message=message, exception=ex) from ex'''

new_method = '''    @staticmethod
    def _write_chunk(chunk, database, data_table, to_sql_kwargs, app):
        """Write a single chunk to database (called in worker thread)"""
        with app.app_context():
            database.db_engine_spec.df_to_sql(
                database,
                data_table,
                chunk,
                to_sql_kwargs=to_sql_kwargs,
            )

    def _dataframe_to_database(
        self,
        df: pd.DataFrame,
        database: Database,
        table_name: str,
        schema_name: Optional[str],
    ) -> None:
        """
        Upload DataFrame to database with parallel chunk writing

        :param df:
        :throws DatabaseUploadFailed: if there is an error uploading the DataFrame
        """
        try:
            data_table = Table(table=table_name, schema=schema_name)
            if_exists = self._options.get("already_exists", "fail")
            use_index = self._options.get("dataframe_index", False)

            to_sql_kwargs = {
                "chunksize": READ_CHUNK_SIZE,
                "if_exists": if_exists,
                "index": use_index,
            }
            if self._options.get("index_label") and use_index:
                to_sql_kwargs["index_label"] = self._options.get("index_label")

            if len(df) <= READ_CHUNK_SIZE * 2:
                database.db_engine_spec.df_to_sql(
                    database,
                    data_table,
                    df,
                    to_sql_kwargs=to_sql_kwargs,
                )
                return

            chunks = [
                df.iloc[i:i + READ_CHUNK_SIZE]
                for i in range(0, len(df), READ_CHUNK_SIZE)
            ]
            parallel_workers = min(6, len(chunks))

            logger.info(
                "Parallel upload: %d rows, %d chunks, %d workers",
                len(df), len(chunks), parallel_workers,
            )

            from flask import current_app
            app = current_app._get_current_object()

            with ThreadPoolExecutor(max_workers=parallel_workers) as executor:
                futures = []
                for idx, chunk in enumerate(chunks):
                    kwargs = {**to_sql_kwargs}
                    if idx > 0:
                        kwargs["if_exists"] = "append"
                    futures.append(
                        executor.submit(
                            self._write_chunk, chunk, database, data_table, kwargs, app
                        )
                    )

                errors = []
                for future in as_completed(futures):
                    try:
                        future.result()
                    except Exception as ex:
                        errors.append(ex)

                if errors:
                    raise errors[0]

        except ValueError as ex:
            raise DatabaseUploadFailed(
                message=_(
                    "Table already exists. You can change your "
                    "'if table already exists' strategy to append or "
                    "replace or provide a different Table Name to use."
                )
            ) from ex
        except Exception as ex:
            message = ex.message if hasattr(ex, "message") and ex.message else str(ex)
            raise DatabaseUploadFailed(message=message, exception=ex) from ex'''

code2 = code2.replace(old_method, new_method)

with open(filepath2, "w") as f:
    f.write(code2)

print("base.py parallel write patch applied")
PATCH_EOF

RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime &&\
    sed -i "s/BABEL_DEFAULT_LOCALE = \"en\"/BABEL_DEFAULT_LOCALE = \"zh\"/" /app/superset/config.py &&\
    sed -i "s/LANGUAGES = {}/LANGUAGES = {\"zh\": {\"flag\": \"cn\", \"name\": \"简体中文\"}, \"en\": {\"flag\": \"us\", \"name\": \"English\"}}/" /app/superset/config.py

USER superset