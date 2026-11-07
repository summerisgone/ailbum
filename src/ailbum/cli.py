from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from ailbum import __version__
from ailbum.catalog import index_library
from ailbum.compare import compare_images
from ailbum.database import (
    connect,
    database_summary,
    get_catalog_image,
    get_person,
    list_catalog_images,
    list_people,
    merge_people,
    name_person,
)
from ailbum.model_download import download_models
from ailbum.models import PipelineConfig
from ailbum.people import compose_person_faces
from ailbum.pipeline import analyze_library
from ailbum.story_evaluation import evaluate_database_stories


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ailbum", description="Многоступенчатый отбор фотографий для альбома"
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)

    analyze = commands.add_parser("analyze", help="проанализировать каталог фотографий")
    analyze.add_argument("source", type=Path, help="файл или каталог с фотографиями")
    analyze.add_argument("-o", "--output", type=Path, default=Path("output"))
    analyze.add_argument("--no-recursive", action="store_true", help="не обходить подкаталоги")
    analyze.add_argument("--sharpness-threshold", type=float, default=100.0)
    analyze.add_argument("--photo-hash-distance", type=int, default=12)
    analyze.add_argument("--photo-hist-similarity", type=float, default=0.72)
    analyze.add_argument("--photo-geometric-similarity", type=float, default=0.55)
    analyze.add_argument(
        "--no-geometric-similarity",
        action="store_true",
        help="отключить геометрическое сравнение SIFT/RANSAC",
    )
    analyze.add_argument("--geometric-max-features", type=int, default=4000)
    analyze.add_argument("--geometric-neighbor-window", type=int, default=12)
    analyze.add_argument("--geometric-time-window-minutes", type=int, default=15)
    analyze.add_argument("--face-similarity", type=float, default=None)
    analyze.add_argument("--min-face-size", type=int, default=40)
    analyze.add_argument(
        "--min-attribute-face-size",
        type=int,
        default=64,
        help="не классифицировать глаза и мимику у лиц меньше этого размера",
    )
    analyze.add_argument("--face-backend", choices=("auto", "classic", "dnn"), default="auto")
    analyze.add_argument(
        "--semantic-backend",
        choices=("auto", "clip", "off"),
        default="auto",
        help="CLIP-оценка эстетики и zero-shot теги (auto, clip или off)",
    )
    analyze.add_argument(
        "--clip-model",
        default="openai/clip-vit-base-patch32",
        help="локальный путь или Hugging Face ID CLIP-модели",
    )
    analyze.add_argument("--semantic-threshold", type=float, default=0.15)
    analyze.add_argument("--semantic-top-k", type=int, default=3)
    analyze.add_argument("--semantic-batch-size", type=int, default=8)
    analyze.add_argument(
        "--semantic-device",
        choices=("auto", "cpu", "mps", "cuda"),
        default="auto",
        help="устройство CLIP; auto предпочитает MPS/CUDA и откатывается на CPU",
    )
    analyze.add_argument(
        "--story-gap-minutes",
        type=int,
        default=120,
        help="обычный временной разрыв между сюжетами",
    )
    analyze.add_argument(
        "--story-continuity-minutes",
        type=int,
        default=360,
        help="максимальный разрыв при совпадении места, людей или сцены",
    )
    analyze.add_argument(
        "--story-max-duration-hours",
        type=int,
        default=12,
        help="максимальная продолжительность одного сюжета",
    )
    analyze.add_argument(
        "--story-semantic-break-minutes",
        type=int,
        default=30,
        help="минимальная пауза, после которой смена сцены разделяет сюжеты",
    )
    analyze.add_argument(
        "--story-naming-backend",
        choices=("auto", "rules", "lmstudio"),
        default="auto",
        help="содержательные названия сюжетов через локальную VL-модель",
    )
    analyze.add_argument("--lmstudio-url", default="http://127.0.0.1:1234/v1")
    analyze.add_argument("--lmstudio-model", default="qwen/qwen3-vl-2b")
    analyze.add_argument("--story-vlm-images", type=int, default=4)
    analyze.add_argument("--story-vlm-timeout", type=float, default=90.0)
    analyze.add_argument("--models-dir", type=Path, default=Path("models"))
    analyze.add_argument("--feature-cache-dir", type=Path, default=None)
    analyze.add_argument(
        "--no-feature-cache",
        action="store_true",
        help="не использовать кэш CV-признаков по SHA-256",
    )
    analyze.add_argument(
        "--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"), help="путь к SQLite"
    )
    analyze.add_argument("--quiet", action="store_true")

    index = commands.add_parser("index", help="добавить изображения и метаданные в SQLite")
    index.add_argument("source", type=Path, help="файл или каталог с фотографиями")
    index.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))
    index.add_argument("--no-recursive", action="store_true", help="не обходить подкаталоги")
    index.add_argument("--quiet", action="store_true")

    database = commands.add_parser("db", help="просмотреть локальную базу изображений")
    database_commands = database.add_subparsers(dest="database_command", required=True)
    stats = database_commands.add_parser("stats", help="показать статистику базы")
    stats.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))
    usage = database_commands.add_parser("usage", help="показать, сколько места занимают данные")
    usage.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))
    listing = database_commands.add_parser("list", help="показать изображения")
    listing.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))
    listing.add_argument("--limit", type=int, default=100)
    listing.add_argument("--json", action="store_true", help="вывести JSON")
    show = database_commands.add_parser("show", help="показать все метаданные изображения")
    show.add_argument("image_id", type=int)
    show.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))

    people = commands.add_parser("people", help="просматривать и объединять найденных людей")
    people_commands = people.add_subparsers(dest="people_command", required=True)
    people_list = people_commands.add_parser("list", help="показать людей")
    people_list.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))
    people_list.add_argument("--limit", type=int, default=100)
    people_list.add_argument("--json", action="store_true")
    person_show = people_commands.add_parser("show", help="показать человека и его лица")
    person_show.add_argument("person_id", type=int)
    person_show.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))
    person_name = people_commands.add_parser("name", help="присвоить человеку имя")
    person_name.add_argument("person_id", type=int)
    person_name.add_argument("name")
    person_name.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))
    person_merge = people_commands.add_parser("merge", help="объединить записи людей")
    person_merge.add_argument("target_id", type=int, help="человек, которого нужно сохранить")
    person_merge.add_argument("source_ids", type=int, nargs="+", help="люди для присоединения")
    person_merge.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))
    person_compose = people_commands.add_parser(
        "compose", help="создать контактный лист всех лиц человека"
    )
    person_compose.add_argument("person_id", type=int)
    person_compose.add_argument("--output", type=Path)
    person_compose.add_argument("--face-size", type=int, default=180)
    person_compose.add_argument("--columns", type=int, default=5)
    person_compose.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))

    models = commands.add_parser(
        "download-models",
        help="загрузить модели лиц, состояния глаз и выражений",
    )
    models.add_argument("--models-dir", type=Path, default=Path("models"))

    compare = commands.add_parser(
        "compare", help="сравнить сходство двух фотографий всеми метриками"
    )
    compare.add_argument("left", type=Path)
    compare.add_argument("right", type=Path)
    compare.add_argument("--photo-hash-distance", type=int, default=12)
    compare.add_argument("--photo-hist-similarity", type=float, default=0.72)
    compare.add_argument("--photo-geometric-similarity", type=float, default=0.55)
    compare.add_argument("--geometric-max-features", type=int, default=4000)
    compare.add_argument("--max-image-side", type=int, default=1600)

    evaluate = commands.add_parser(
        "evaluate-stories", help="оценить сюжеты по ручной Markdown-разметке"
    )
    evaluate.add_argument("annotations", type=Path)
    evaluate.add_argument("--database", type=Path, default=Path(".ailbum/ailbum.sqlite3"))
    evaluate.add_argument("--run-id")

    db_default = Path(".ailbum/ailbum.sqlite3")
    album = commands.add_parser("album", help="управлять альбомами")
    album_commands = album.add_subparsers(dest="album_command", required=True)
    album_list = album_commands.add_parser("list", help="показать альбомы")
    album_list.add_argument("--json", action="store_true")
    for name, text in (
        ("show", "показать альбом"),
        ("order", "отметить альбом заказанным"),
        ("reopen", "вернуть заказанный альбом в работу"),
        ("delete", "удалить альбом"),
        ("archive", "освободить место: перенести оригиналы альбома в Корзину"),
        ("export", "скопировать оригиналы альбома в папку"),
    ):
        item = album_commands.add_parser(name, help=text)
        item.add_argument("album_id", type=int)
        if name == "delete":
            item.add_argument(
                "--forget-decisions", action="store_true", help="удалить и накопленные решения"
            )
        if name == "archive":
            item.add_argument("--yes", action="store_true", help="не спрашивать подтверждение")
        if name == "export":
            item.add_argument("--folder", type=Path, required=True)
    for item in album_commands.choices.values():
        item.add_argument("--database", type=Path, default=db_default)

    forget = commands.add_parser("forget", help="забыть накопленные знания об альбоме или каталоге")
    target = forget.add_mutually_exclusive_group(required=True)
    target.add_argument("--album", type=int, dest="album_id")
    target.add_argument("--source")
    forget.add_argument("--yes", action="store_true", help="выполнить, а не только показать план")
    forget.add_argument("--database", type=Path, default=db_default)

    ranking = commands.add_parser("ranking", help="обучаемый выбор фотографий")
    ranking_commands = ranking.add_subparsers(dest="ranking_command", required=True)
    for name, text in (
        ("train", "обучить ранкер по правкам альбомов"),
        ("status", "показать состояние ранкера"),
        ("evaluate", "проверить ранкер без сохранения"),
    ):
        ranking_commands.add_parser(name, help=text).add_argument(
            "--database", type=Path, default=db_default
        )
    return parser


def _dump(value: object) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2))


def _album_command(args: argparse.Namespace) -> None:
    from ailbum import albums
    from ailbum.archive import complete_archive, prepare_archive, trash_paths

    command = args.album_command
    if command == "archive":
        plan = prepare_archive(args.database, args.album_id)
        for item in plan["blocked"]:
            print(f"Не удаляем фото {item['image_id']}: {item['reason']}")
        if plan["needs_export"]:
            print(
                "Нужен экспорт: сначала выполните "
                f"ailbum album export {args.album_id} --folder ПАПКА"
            )
            raise SystemExit(1)
        paths = plan["trash"]
        if paths and not args.yes:
            try:
                answer = input(f"Перенести {len(paths)} файлов в Корзину? [y/N] ")
            except EOFError:
                answer = ""
            if answer.strip().lower() not in ("y", "yes", "д", "да"):
                print("Отменено")
                return
        trashed = trash_paths(paths) if paths else []
        _dump(complete_archive(args.database, args.album_id, trashed))
        return
    if command == "export":
        from ailbum.layout.export import export_originals

        _dump(export_originals(args.database, args.album_id, args.folder))
        return
    with connect(args.database) as connection:
        if command == "list":
            found = albums.list_albums(connection)
            if args.json:
                _dump(found)
                return
            print("ID\tСтатус\tНазвание\tФото")
            for item in found:
                print(
                    f"{item['id']}\t{item['status']}\t{item['title']}\t"
                    f"{item['photo_count']}/{item['target_count']}"
                )
        elif command == "show":
            _dump(albums.get_album(connection, args.album_id))
        elif command == "order":
            _dump(albums.set_status(connection, args.album_id, "ordered"))
        elif command == "reopen":
            _dump(albums.set_status(connection, args.album_id, "draft"))
        else:
            albums.delete_album(connection, args.album_id, args.forget_decisions)
            print(f"Альбом {args.album_id} удалён")


def _forget_command(args: argparse.Namespace) -> None:
    from ailbum import forget

    _dump(forget.plan_forget(args.database, args.album_id, args.source))
    if args.yes:
        _dump(forget.forget(args.database, args.album_id, args.source))
    else:
        print("Это только план. Добавьте --yes, чтобы выполнить.")


def _ranking_command(args: argparse.Namespace) -> None:
    from ailbum.ranking import train

    with connect(args.database) as connection:
        _dump(getattr(train, args.ranking_command)(connection))


def _usage_command(args: argparse.Namespace) -> None:
    from ailbum import forget

    data = forget.usage(args.database)
    mb = 1024 * 1024
    print(f"База данных: {data['database_bytes'] / mb:.1f} МБ")
    print(f"Превью: {data['proxies_bytes'] / mb:.1f} МБ")
    print(f"Кэш признаков: {data['feature_cache_bytes'] / mb:.1f} МБ")
    images = data["images"]
    print(
        f"Оригиналы: на месте {images['present']}, нет файла {images['missing']}, "
        f"в архиве {images['archived']}"
    )


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "download-models":
            for path in download_models(args.models_dir):
                print(path)
            return
        if args.command == "compare":
            print(
                json.dumps(
                    compare_images(
                        args.left,
                        args.right,
                        hash_distance=args.photo_hash_distance,
                        histogram_threshold=args.photo_hist_similarity,
                        geometric_threshold=args.photo_geometric_similarity,
                        geometric_max_features=args.geometric_max_features,
                        max_image_side=args.max_image_side,
                    ),
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return
        if args.command == "evaluate-stories":
            print(
                json.dumps(
                    evaluate_database_stories(
                        args.database, args.annotations, run_id=args.run_id
                    ),
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return
        if args.command == "index":
            summary = index_library(
                args.source,
                args.database,
                recursive=not args.no_recursive,
                progress=None if args.quiet else print,
            )
            print(json.dumps(summary, ensure_ascii=False, indent=2))
            print(f"База данных: {args.database.resolve()}")
            return
        if args.command == "db":
            if args.database_command == "usage":
                _usage_command(args)
                return
            if args.database_command == "stats":
                print(json.dumps(database_summary(args.database), ensure_ascii=False, indent=2))
                return
            if args.database_command == "show":
                print(
                    json.dumps(
                        get_catalog_image(args.database, args.image_id),
                        ensure_ascii=False,
                        indent=2,
                    )
                )
                return
            images = list_catalog_images(args.database, limit=args.limit)
            if args.json:
                print(json.dumps(images, ensure_ascii=False, indent=2))
            else:
                print("ID\tДата съёмки\tРазмер\tКамера\tПуть")
                for image in images:
                    dimensions = f"{image['width']}x{image['height']}"
                    camera = " ".join(
                        value
                        for value in (image["camera_make"], image["camera_model"])
                        if value
                    )
                    print(
                        f"{image['id']}\t{image['taken_at'] or '-'}\t{dimensions}\t"
                        f"{camera or '-'}\t{image['path']}"
                    )
            return
        if args.command == "album":
            _album_command(args)
            return
        if args.command == "forget":
            _forget_command(args)
            return
        if args.command == "ranking":
            _ranking_command(args)
            return
        if args.command == "people":
            if args.people_command == "list":
                found_people = list_people(args.database, limit=args.limit)
                if args.json:
                    print(json.dumps(found_people, ensure_ascii=False, indent=2))
                else:
                    print("ID\tИмя\tЛица\tФото\tМодель")
                    for person in found_people:
                        print(
                            f"{person['id']}\t{person['name'] or '-'}\t"
                            f"{person['face_count']}\t{person['photo_count']}\t"
                            f"{person['embedding_model']}"
                        )
                return
            if args.people_command == "show":
                result = get_person(args.database, args.person_id)
            elif args.people_command == "name":
                result = name_person(args.database, args.person_id, args.name)
            elif args.people_command == "merge":
                result = merge_people(args.database, args.target_id, args.source_ids)
            else:
                output = args.output or Path("output/people") / f"person-{args.person_id}.jpg"
                result = compose_person_faces(
                    args.database,
                    args.person_id,
                    output,
                    face_size=args.face_size,
                    columns=args.columns,
                )
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return

        config = PipelineConfig(
            sharpness_threshold=args.sharpness_threshold,
            photo_hash_distance=args.photo_hash_distance,
            photo_hist_similarity=args.photo_hist_similarity,
            photo_geometric_similarity=(
                None if args.no_geometric_similarity else args.photo_geometric_similarity
            ),
            geometric_max_features=args.geometric_max_features,
            geometric_neighbor_window=args.geometric_neighbor_window,
            geometric_time_window_minutes=args.geometric_time_window_minutes,
            face_similarity=args.face_similarity,
            min_face_size=args.min_face_size,
            min_attribute_face_size=args.min_attribute_face_size,
            face_backend=args.face_backend,
            semantic_backend=args.semantic_backend,
            clip_model=args.clip_model,
            semantic_threshold=args.semantic_threshold,
            semantic_top_k=args.semantic_top_k,
            semantic_batch_size=args.semantic_batch_size,
            semantic_device=args.semantic_device,
            story_gap_minutes=args.story_gap_minutes,
            story_continuity_minutes=args.story_continuity_minutes,
            story_max_duration_hours=args.story_max_duration_hours,
            story_semantic_break_minutes=args.story_semantic_break_minutes,
            story_naming_backend=args.story_naming_backend,
            lmstudio_url=args.lmstudio_url,
            lmstudio_model=args.lmstudio_model,
            story_vlm_images=args.story_vlm_images,
            story_vlm_timeout=args.story_vlm_timeout,
            models_dir=args.models_dir,
            feature_cache=not args.no_feature_cache,
            feature_cache_dir=args.feature_cache_dir,
        )
        manifest = analyze_library(
            args.source,
            args.output,
            config,
            recursive=not args.no_recursive,
            progress=None if args.quiet else print,
            database=args.database,
        )
        summary = manifest["summary"]
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        from ailbum import albums

        with connect(args.database) as connection:
            album_id = albums.attach_run(
                connection, str(manifest["run_id"]), [str(args.source.resolve())]
            )
        print(f"Альбом: {album_id}")
        print(f"Результаты: {(args.output / 'analysis.json').resolve()}")
        print(f"База данных: {args.database.resolve()}")
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        raise SystemExit(2) from error


if __name__ == "__main__":
    main()
