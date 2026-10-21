package dev.fluxdown.android.data

/**
 * 作者: long
 * 用持久化在任务里的文件清单拼出详情视图，作为运行中查询的兜底。
 * 已完成任务没有活动 session，直接把每个文件的进度视为已下载完成。
 */
internal fun savedTorrentSelection(task: QueueTask, outputPath: String): TorrentSelection =
    TorrentSelection(
        source = task.source,
        requestedFileName = task.name,
        outputPath = outputPath,
        directoryName = task.torrentName ?: task.name,
        files = task.torrentFiles
            .filter { task.torrentFileIndices.isEmpty() || it.index in task.torrentFileIndices }
            .map { file ->
                if (task.state == "finished") file.copy(progressBytes = file.size) else file
            },
        infoHash = null,
    )
