list.of.packages <- c("httr", "DBI", "RPostgres","data.table","tidyverse")
new.packages <- list.of.packages[!(list.of.packages %in% installed.packages()[,"Package"])]
if(length(new.packages)) install.packages(new.packages)

library(httr)
library(DBI)
library(RPostgres)
library(data.table)
library(tidyverse)

Correct_Colnames <- function(df) {
  rowval <- gsub("^X\\.", "-",  colnames(df))
  rowval <- gsub("^X", "",  rowval)
  DatePattern = '^[[:digit:]]{4}\\.[[:digit:]]{2}\\.[[:digit:]]{2}[T,\\.][[:digit:]]{2}\\.[[:digit:]]{2}\\.[[:digit:]]{2}(.[[:digit:]]{3})?[Z]?'
  rowval[which(grepl(DatePattern,rowval))] <- as.character(as.POSIXct(rowval[grepl(DatePattern,rowval)], format="%Y.%m.%d.%H.%M.%S", tz="UTC"))
  return(rowval)}

is.POSIXct <- function(x) inherits(x, "POSIXct")  
resave <- function(..., list = character(), file) {
  previous  <- load(file)
  var.names <- c(list, as.character(substitute(list(...)))[-1L])
  for (var in var.names) assign(var, get(var, envir = parent.frame()))
  save(list = unique(c(previous, var.names)), file = file)
}

host <- 'https://api.internetofwildlife.com/' #'https://account.celltracktech.com'
project <- '/station/api/projects'
stations <- '/station/api/stations/'
files <- '/station/api/file-list'
file_types <- c("data", "node-data", "gps", "log", "telemetry", "sensorgnome")

post <- function(endpoint, payload=NULL) {
  payload_to_send <- list(token=my_token)
  if (!is.null(payload)) {
    payload_to_send <- c(payload_to_send, payload)
  }
  print(endpoint)
  response <- POST(host, path = endpoint, body=payload_to_send,encode="json", timeout(60)) 
  stop_for_status(response)
  return(response)
}

getStations <- function(project_id) {
  out <- post(endpoint=stations, payload=list("project-id"=project_id))
  return(content(out))
}

getStationFileList <- function(station_id, begin, filetypes=NULL, end=NULL) {
  endpoint <- files
  payload <- list("station-id" = station_id, begin = as.Date(begin))
  if (!is.null(filetypes)) {
    add_types <- filetypes[filetypes %in% file_types]
    if(length(which(!filetypes %in% file_types)) > 0) {print(paste("WARNING: invalid file type specified - ignoring:",filetypes[!filetypes %in% file_types]))}
    payload[['file-types']] = add_types
  } 
  if (!is.null(end)) {payload[['end']] = as.Date(end)}
return(content(post(endpoint=endpoint, payload=payload)))}

downloadFiles <- function(file_id) {
  endpoint <- "/station/api/download-file/"
  payload <- list("file-id"=file_id)
  return(post(endpoint=endpoint, payload=payload))
}

create_db <- function(conn, projects) {
dbExecute(conn, "CREATE TABLE IF NOT EXISTS ctt_project
  (
    id	smallint PRIMARY KEY,
    name	TEXT NOT NULL UNIQUE
  )")
#

dbExecute(conn, "CREATE TABLE IF NOT EXISTS nodes
  (
    node_id TEXT NOT NULL PRIMARY KEY
  )")

dbExecute(conn, "CREATE TABLE IF NOT EXISTS data_file
  (
    path TEXT PRIMARY KEY
  )")

dbExecute(conn, "CREATE TABLE IF NOT EXISTS ctt_project_station 
  (
    db_id	smallint PRIMARY KEY,
    project_id smallint NOT NULL,
    station_id	TEXT NOT NULL,
    deploy_at	TIMESTAMP with time zone,
    end_at	TIMESTAMP with time zone,
    FOREIGN KEY (project_id) 
      REFERENCES ctt_project (id) 
        ON DELETE NO ACTION
        ON UPDATE NO ACTION
  )")

dbExecute(conn, "CREATE TABLE IF NOT EXISTS raw 
  (
    id	SERIAL PRIMARY KEY,
    path  TEXT NOT NULL,
    radio_id smallint NOT NULL,
    tag_id TEXT,
    node_id TEXT,
    tag_rssi smallint,
    validated smallint,
    time TIMESTAMP with time zone NOT NULL,
    station_id TEXT
  )")

dbExecute(conn, "CREATE TABLE IF NOT EXISTS node_health
  (
    PRIMARY KEY (radio_id, node_id, time, station_id),
    time TIMESTAMP with time zone NOT NULL,
    radio_id smallint,
    node_id TEXT,
    node_rssi smallint,
    battery NUMERIC(3,2),
    celsius smallint,
    recorded_at TIMESTAMP with time zone,
    firmware TEXT,
    solar_volts NUMERIC(4,2),
    solar_current smallint,
    cumulative_solar_current integer,
    latitude NUMERIC(8,6),
    longitude NUMERIC(9,6),
    station_id TEXT,
    path  TEXT NOT NULL,
    FOREIGN KEY (node_id) 
      REFERENCES nodes (node_id) 
        ON DELETE NO ACTION
        ON UPDATE NO ACTION
  )")

dbExecute(conn, "CREATE TABLE IF NOT EXISTS gps
  (
    path  TEXT NOT NULL,
    latitude NUMERIC(8,6),
    longitude NUMERIC(9,6),
    altitude NUMERIC(6,1),
    quality smallint,
    gps_at TIMESTAMP with time zone,
    recorded_at TIMESTAMP with time zone,
    station_id TEXT,
    mean_lat NUMERIC(8,6),
    mean_lng NUMERIC(9,6),
    n_fixes smallint,
    PRIMARY KEY (gps_at, station_id)
  )")

  sapply(projects, function(a) {
    b <- unname(as.data.frame(a))
    vars <- paste(dbListFields(conn, "ctt_project"), sep="", collapse=",")
    insertnew <- dbSendQuery(conn, paste("INSERT INTO ","ctt_project"," (",vars,") VALUES ($1, $2) ON CONFLICT DO NOTHING",sep="")) 
  #it is possible you should be using dbSendStatement for all of these
    dbBind(insertnew, params=b)
    dbClearResult(insertnew)
  
    basename <- a$name
    id <- a[['id']]
    my_stations <- getStations(project_id=id)
    print("RETURNED FROM API")
    print(my_stations)
    mystations <- lapply(my_stations$stations, function(c) {
      c <- as.data.frame(t(unlist(c)), stringsAsFactors=FALSE)
    
      c$project_id <- id
      colnames(c)[colnames(c)=="station.db-id"] <- "db_id"
      colnames(c)[colnames(c)=="station.id"] <- "station_id"
      colnames(c)[colnames(c)=="deploy-at"] <- "deploy_at"
      if (is.null(c$`end-at`)) {
        c$end_at <- NA} else {colnames(c)[colnames(c)=="end-at"] <- "end_at"}
      return(c)})
    mystations <- as.data.frame(rbindlist(mystations, fill=TRUE))
    MYSTATIONS <- list(unique(mystations$station_id))
    mystations <- unname(mystations)
    print("FORMATTED")
    print(mystations)
  
  #insertnew <- dbSendQuery(conn, paste("INSERT INTO ","station (station_id)"," VALUES ($1)
  #                                     ON CONFLICT DO NOTHING",sep=""))
  #dbBind(insertnew, params=MYSTATIONS)
  #dbClearResult(insertnew)
  
    vars <- paste(dbListFields(conn, "ctt_project_station"), sep="", collapse=",")
    #print(vars)
    insertnew <- dbSendQuery(conn, paste("INSERT INTO ","ctt_project_station"," (",vars,") VALUES ($1, $4, $2, $3, $5)
                                       ON CONFLICT DO NOTHING",sep=""))
    dbBind(insertnew, params=mystations)
    dbClearResult(insertnew)
  })
}

querygen <- function(mycont) {
  pieces <- paste(names(mycont), mycont, sep=" = ")
  na <- grep(" = NA", pieces)
  if (length(na > 0)) {pieces[na] <- gsub("= NA","is null",pieces[na])}
  pieces <- paste(pieces, collapse=" and ")
  return(pieces)
}
timeset <- function(g) {unname(sapply(g, function(h) ifelse(is.na(h), NA, paste(as.character(h), "UTC"))))}
db_insert <- function(contents, filetype, conn, sensor, y, begin) {
  print(filetype)
  print(str(contents))
  print(begin)
  if("Time" %in% colnames(contents)) {
    if(is.character(contents$Time)) { #does this just handle 1 broken date? if so, what happens when there are more broken rows?
      DatePattern = '[[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}[T, ][[:digit:]]{2}:[[:digit:]]{2}:[[:digit:]]{2}(.[[:digit:]]{3})?[Z]?'
      exactDatePattern = '^[[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}[T, ][[:digit:]]{2}:[[:digit:]]{2}:[[:digit:]]{2}(.[[:digit:]]{3})?[Z]?$'
      brokenrow <- grep(exactDatePattern, contents$Time, invert=TRUE) #find row that has a date embedded in a messed up string (i.e. interrupted rows)
      contents[brokenrow,1]<- str_extract(contents[brokenrow,1], DatePattern)
      contents$Time <- as.POSIXct(contents$Time)
      contents <- filter(contents, Time < Sys.time() & Time > begin)
    } else {
    contents <- filter(contents, Time < Sys.time() & Time > begin)
    }
    print(contents)
    #contents <- contents[contents$Time < Sys.time() & contents$Time > begin,]
  }
  contents[,unname(which(sapply(contents, is.POSIXct)))] <- ifelse(nrow(contents[,unname(which(sapply(contents, is.POSIXct)))]) > 1,
                                                                   as_tibble(apply(contents[,unname(which(sapply(contents, is.POSIXct)))], 2,
                                                                                   timeset)),
    bind_rows(apply(contents[,unname(which(sapply(contents, is.POSIXct)))], 2, timeset)))
  
  contents <- data.frame(contents)

  contents$station_id <- sensor
  contents$path <- y

  if(!is.null(contents)) {
    if (filetype == "gps") {
      colnames(contents)[colnames(contents)=="recorded.at"] <- "recorded_at"
      contents$recorded_at <- as.character(contents$recorded_at)
      colnames(contents)[colnames(contents)=="gps.at"] <- "gps_at"
      contents$gps_at <- as.character(contents$gps_at)
      if ("mean.lat" %in% colnames(contents)) {
        colnames(contents)[colnames(contents)=="mean.lat"] <- "mean_lat"
        colnames(contents)[colnames(contents)=="mean.lng"] <- "mean_lng"
        colnames(contents)[colnames(contents)=="n.fixes"] <- "n_fixes"
      } else {
        contents$mean_lat <- NA
        contents$mean_lng <- NA
        contents$n_fixes <- NA
      }
    names(contents) <- sapply(names(contents), function(x) gsub('([[:lower:]])([[:upper:]])', '\\1_\\2', x))
    #if(fix=TRUE) {
    #  query <- querygen(contents[1,])
    #  res <- dbGetQuery(conn, paste0("select * from gps where ", query))
    #  if(nrow(res) > 0) {
    #    me <- data.frame(matrix(ncol=ncol(contents), nrow=0))
    #    names(me) <- names(contents)
    #    contents <- me
    #  }
    #}
    } else if (filetype == "raw") {
      print(names(contents))
      if (!(any(tolower(names(contents))=="validated"))) {contents$validated <- NA}
      contents$RadioId <- as.integer(contents$RadioId)
      contents$TagRSSI <- as.integer(contents$TagRSSI)
      if (length(which(!is.na(contents$NodeId))) > 0) {
        nodeids <- contents$NodeId[which(!is.na(contents$NodeId))]
        insertnew <- dbSendQuery(conn, paste("INSERT INTO ","nodes (node_id)"," VALUES ($1)
                                           ON CONFLICT DO NOTHING",sep=""))
        dbBind(insertnew, params=list(unique(nodeids)))
        dbClearResult(insertnew)
      }
      if(length(which(nchar(contents$TagId) != 8)) > 0) {
        contents <- contents[-which(nchar(contents$TagId) != 8),] #drop rows where TagId not 8 characters
      }
      names(contents) <- sapply(names(contents), function(x) gsub('([[:lower:]])([[:upper:]])', '\\1_\\2', x))
      #if(fix=TRUE) {
      #  query <- querygen(contents[1,])
      #  res <- dbGetQuery(conn, paste0("select * from raw where ", query))
      #  if(nrow(res) > 0) {
      #    me <- data.frame(matrix(ncol=ncol(contents), nrow=0))
      #    names(me) <- names(contents)
      #    contents <- me
      #  }
      #}
    } else if (filetype == "node_health") {

      contents$Battery[which(contents$Battery > 9)] <- NA
      if(ncol(contents) < 9) {
        contents$RecordedAt <- NA
        contents$Firmware <- NA
        contents$SolarVolts <- NA
        contents$SolarCurrent <- NA
        contents$CumulativeSolarCurrent <- NA
        contents$Latitude <- NA
        contents$Longitude <- NA
      }
      nodeids <- unique(contents$NodeId)
      insertnew <- dbSendQuery(conn, paste("INSERT INTO ","nodes (node_id)"," VALUES ($1)
                                           ON CONFLICT DO NOTHING",sep=""))
      dbBind(insertnew, params=list(unique(nodeids)))
      dbClearResult(insertnew)
      names(contents) <- sapply(names(contents), function(x) gsub('([[:lower:]])([[:upper:]])', '\\1_\\2', x))
      #if(fix=TRUE) {
      #  query <- querygen(contents[1,])
      #  res <- dbGetQuery(conn, paste0("select * from node_health where ", query))
      #  if(nrow(res) > 0) {
      #    me <- data.frame(matrix(ncol=ncol(contents), nrow=0))
      #    names(me) <- names(contents)
      #    contents <- me
        #}
      #}
    } else {nodeids <- c()}
    if (filetype %in% c("raw", "node_health", "gps")) {
      #print(str(contents))
      #print(dbListFields(conn, filetype))
      if (filetype == "raw") {
        vars <- paste(dbListFields(conn, filetype)[2:length(dbListFields(conn, filetype))], sep="", collapse=",") 
        vals <- paste(seq_along(1:(length(dbListFields(conn, filetype))-1)), sep="", collapse = ", $")
        names(contents) <- tolower(names(contents))
        contents <- contents[,dbListFields(conn, filetype)[2:length(dbListFields(conn, filetype))]]
      } else {
      vars <- paste(dbListFields(conn, filetype), sep="", collapse=",") 
      vals <- paste(seq_along(1:length(dbListFields(conn, filetype))), sep="", collapse = ", $")
      names(contents) <- tolower(names(contents))
      contents <- contents[,dbListFields(conn, filetype)]
      }
      h <- tryCatch({tryCatch({
          if(any(row.names(contents) == "NA")) {contents <- contents[-which(row.names(contents)=="NA"),]}
        #if(fixthis = TRUE) {
          #fill out here
        #} else {
          dbWriteTable(conn, filetype, contents, append=TRUE)
          insertnew <- dbSendQuery(conn, paste("INSERT INTO ","data_file (path)"," VALUES ($1)
                                         ON CONFLICT DO NOTHING",sep=""))
          dbBind(insertnew, params=list(y))
          dbClearResult(insertnew)
          NULL
        #}
        }, error = function(err) {
          # error handler picks up where error was generated, in Bob's script it breaks if header is missing
          myquery <- paste("INSERT INTO ", filetype, " (", vars,") VALUES ($",vals,")
                                         ON CONFLICT DO NOTHING",sep="")
          insertnew <- dbSendQuery(conn, myquery)
          dbBind(insertnew, params=unname(contents))
          dbClearResult(insertnew)
        })
      }, error = function(err) {
        print("could not insert")
        return(list(err, contents, y))
        }
        )
    }
  }
  if(!exists("h")) {h <- NULL}
return(h)}

get_data <- function(thisproject, outpath, f=NULL, my_station, beginning, ending) {
  #print("getting your file list")
  myfiles <- list.files(outpath, recursive = TRUE)
  files_loc <- sapply(strsplit(myfiles, "/"), tail, n=1)
  basename <- thisproject$name
  id <- thisproject[['id']]
  dir.create(file.path(outpath, basename), showWarnings = FALSE)
  my_stations <- getStations(project_id=id)
  if(!is.null(my_station)) {
    my_stations[["stations"]] <- list(my_stations[[1]][[which(sapply(my_stations[[1]], function(x) x[['station']][["id"]] == my_station))]])
  }
  files_avail <- lapply(my_stations[["stations"]], function(station, mybeginning=beginning, myending=ending) {
    print(station)
    if(is.null(mybeginning)) {
      beginning = as.POSIXct(station[['deploy-at']],format="%Y-%m-%dT%H:%M:%OS",tz = "UTC", optional=TRUE)
    } else {beginning = as.POSIXct(as.Date(mybeginning),format="%Y-%m-%dT%H:%M:%OS",tz = "UTC", optional=TRUE)}
    kwargs <- list(
      station_id = station[["station"]][["id"]],
      begin = beginning
    )
    print(is.null(myending))
    if(!is.null(myending)) {
      kwargs[['end']] = as.POSIXct(as.Date(myending),format="%Y-%m-%dT%H:%M:%OS",tz = "UTC", optional=TRUE)
    } else if(!is.null(station[['end-at']])) {
      kwargs[['end']] = as.POSIXct(station[['end-at']],format="%Y-%m-%dT%H:%M:%OS",tz = "UTC", optional=TRUE)
    }
    
    print(kwargs)
    #print("getting station file list...")
    file_info <- do.call(getStationFileList, kwargs)
    outfiles <- file_info[['files']]
    #print(outfiles)
    #print(paste(length(outfiles), "files available"))
  return(outfiles)})
  print("getting files available for those stations...")
  filenames <- unname(rapply(files_avail, grep, pattern = "CTT", value=TRUE))
  print("got the file list; comparing against your files")
  files_to <- filenames[!filenames %in% files_loc]
  print("comparison complete")

  allfiles <- rapply(files_avail, function(z) z %in% files_to, how = "unlist") #this is the super intensive, time consuming function...
  ids <- unlist(files_avail)[which(allfiles) - 1]
  print(paste("about to get", length(ids), "files"))
  file_names <- unlist(files_avail)[which(allfiles)]
  print("prepped list of filenames to get")

  get_files <- function(x, y) {

    print(x)
    print(y)
    splitfile <- unlist(strsplit(y, "CTT-"))
    fileinfo <- splitfile[2]
    sensorid <- unlist(strsplit(fileinfo,"-"))
    sensor <- sensorid[1]
    faul <- which(sapply(my_stations[["stations"]], function(sta) sta$station$id==sensor)) 
    if(length(faul) > 1) {
      begin <- sapply(faul, function(x) as.POSIXct(my_stations[["stations"]][[x]]$`deploy-at`,format="%Y-%m-%dT%H:%M:%OS",tz = "UTC", optional=TRUE))
      begin <- max(begin)
    } else {begin <- as.POSIXct(my_stations[["stations"]][[faul]]$`deploy-at`,format="%Y-%m-%dT%H:%M:%OS",tz = "UTC", optional=TRUE)}
    print(paste("look here", faul))
    print(my_stations[["stations"]])
    filenameinfo <- sensorid[2]
    file_info <- unlist(strsplit(filenameinfo, "\\."))[1]
    filetype <- ifelse(is.na(as.integer(file_info)),file_info,"sensorgnome")
    print(filetype)
    if (is.na(filetype)) {
      filetype <- "none"
    } else if (filetype == "node") {
      filetype <- "node_health"
    } else if (filetype == "data") {
      filetype <- "raw"
    }
    
    if (filetype != "log" & filetype != "telemetry" & filetype != "sensorgnome") {
      contents = downloadFiles(file_id = x)
      if (filetype == "raw") {
        contents <- content(contents, type="text", col_types = list(NodeId = 'c'))
      } else {
        contents <- content(contents, type="text")
      }
      if (!is.null(contents)) {
      dir.create(file.path(outpath, basename, sensor), showWarnings = FALSE)
      dir.create(file.path(outpath, basename, sensor, filetype), showWarnings = FALSE)
      print(paste("downloading",y,"to",file.path(outpath, basename, sensor, filetype)))
      print(x)
      write(contents, file=gzfile(file.path(outpath, basename, sensor, filetype, y)))
      contents <- tryCatch({
          read_csv(file.path(outpath, basename, sensor, filetype, y), col_names = TRUE)
        }, error = function(err) {
          return(NULL)
        })
      if(!is.null(contents)) {
        delete.columns <- grep("(^X)", colnames(contents), perl=T)
        if (length(delete.columns) > 0) {
          contents <- rbind(contents,Correct_Colnames(contents))
        }
        if(filetype == "raw") {
          if (length(delete.columns) > 0) {
            if(ncol(contents) > 5) {
              names(contents) <- c("Time","RadioId","TagId","TagRSSI","NodeId","Validated")
            } else {names(contents) <- c("Time","RadioId","TagId","TagRSSI","NodeId")}
          }
          v <- ifelse(any(colnames(contents)=="Validated"), 2, 1)
          correct <- ifelse(v < 2, 5, 6)
          indx <- count.fields(file.path(outpath, basename, sensor, filetype, y), sep=",")
          if(any(indx != correct)) {
            rowfix <- which(indx != correct) - 1
            getrow <- read.csv(file.path(outpath, basename, sensor, filetype, y),as.is=TRUE, na.strings=c("NA", ""), skipNul = TRUE, skip=rowfix-1, nrow=1)
            getrow[,1]<- str_extract(getrow[,1], DatePattern) #handling assumes e.g. extra field and correct record starts in column 2
            if(any(grepl("T", getrow[,1]))) {
              vals <- as.POSIXct(getrow[,1],format="%Y-%m-%dT%H:%M:%OS",tz = "UTC", optional=TRUE)
            } else {
              vals <- unname(sapply(getrow[,1], function(x) as.POSIXct(x, format="%Y-%m-%d %H:%M:%OS", tz = "UTC", optional=TRUE)))
              vals1 <- sapply(vals, function(x) format(as.POSIXct(x, origin="1970-01-01", tz="UTC"),"%Y-%m-%d %H:%M:%OS"))
              vals <- as.POSIXct(vals1, tz="UTC")
            }
            getrow[,1] <- vals
            getrow[,3] <- as.character(getrow[,3])
            contents[rowfix,] <- getrow[1,]
          }
        } else if(filetype=="gps") {
          if(length(delete.columns) > 0) {
            if(ncol(contents) > 8) {
              names(contents) <- c("recorded.at","gps.at","latitude","longitude","altitude","quality","mean.lat","mean.lng","n.fixes")
            } else {names(contents) <- c("recorded.at","gps.at","latitude","longitude","altitude","quality")}
            }
        } else if(filetype == "node_health") {
          if (length(delete.columns) > 0) {
            if(ncol(contents) > 9) {
              names(contents) <- c("Time","RadioId","NodeId","NodeRssi","Battery","celsius","RecordedAt","firmware","SolarVolts","SolarCurrent","CumulativeSolarCurrent","latitude","longitude")
            } else {
               names(contents) <- c("Time","RadioId","NodeId","NodeRssi","Battery","celsius")
            }
          }
        }
        }
      if(!is.null(f)) {
        print(begin)
        z <- db_insert(contents, filetype, f, sensor, y, begin)
      }
      }
    }
    if(!exists("z")) {z <- NULL}
  return(z)}

failed <- Map(get_files, ids, file_names)
return(failed)}

get_my_data <- function(my_token, outpath, db_name=NULL, myproject=NULL, mystation=NULL, begin=NULL, end=NULL) {
  projects <- content(POST(host, path = project, body = list(token=my_token), encode="json", verbose()), "parsed")
  print(projects)
  projects <- projects[['projects']]
  #print(projects)
  if(!is.null(myproject)) {
    projects <- list(projects[[which(sapply(projects, function(x) x[["name"]]) == myproject)]])
  }
  
  if(!is.null(db_name)) {
    create_db(db_name, projects)
    failed <- lapply(projects, get_data, f=db_name, outpath=outpath, my_station=mystation, beginning=begin, ending=end)
  } else {
      failed <- lapply(projects, get_data, outpath=outpath, my_station=mystation, beginning=begin, ending=end)
  }
  faul <- which(!sapply(failed[[1]], is.null)) 
  if(length(faul > 0)) {
  failed <- Map(`[`, failed, faul)
  save(failed,file=file.path(outpath, "caught.RData"))
  } else {
    failed <- "all good!"
    save(failed,file=file.path(outpath, "caught.RData"))
  }
}

pop <- function(x) { #this was a function written before the data file table was added, no one should need this
  allnode <- dbReadTable(x, "node_health")
  allgps <- dbReadTable(x, "gps")
  allbeep <- dbReadTable(x, "raw")
  insertnew <- dbSendQuery(conn, paste("INSERT OR IGNORE INTO ","data_file (path)"," VALUES ($)",sep=""))
  dbBind(insertnew, params=list(unique(c(allnode$path, allgps$path, allbeep$path))))
  dbClearResult(insertnew)
  
  insertnew <- dbSendQuery(conn, paste("INSERT OR IGNORE INTO ","nodes (node_id)"," VALUES ($)",sep=""))
  dbBind(insertnew, params=list(unique(allnode$node_id)))
  dbClearResult(insertnew)
}

update_db <- function(d, outpath, myproject, fix=FALSE) {
  myfiles <- list.files(file.path(outpath, myproject), recursive = TRUE)
  files_loc <- sapply(strsplit(myfiles, "/"), tail, n=1)
  allnode <- dbReadTable(d, "data_file")
  if(fix) {
    res <- dbGetQuery(d, "select distinct path from gps")
    res2 <- dbGetQuery(d, "select distinct path from raw")
    res1 <- dbGetQuery(d, "select distinct path from node_health")
    filesdone <- c(res$path, res1$path, res2$path)
  } else {
    filesdone <- allnode$path
  }
  files_import <- myfiles[which(!files_loc %in% filesdone)]
  write.csv(files_import, file.path(outpath,"files.csv"))
  failed2 <- lapply(files_import, get_files_import, conn=d, outpath=outpath, myproject=myproject)
  faul <- which(!sapply(failed2[[1]], is.null)) 
  if(length(faul) > 0) {
  failed2 <- Map(`[`, failed2, faul)
  resave(failed2, file=file.path(outpath, "caught.RData"))
  } else {
    failed2 <- "all good!"
    resave(failed2, file=file.path(outpath, "caught.RData"))
    }
}

get_files_import <- function(e, conn, outpath, myproject) {
  e <- file.path(outpath, myproject, e)
  print(e)
  y <- tail(unlist(strsplit(e, "/")), n=1)

  splitfile <- unlist(strsplit(y, "CTT-"))
  fileinfo <- splitfile[2]
  sensorid <- unlist(strsplit(fileinfo,"-"))
  sensor <- sensorid[1]
  i <- dbReadTable(conn, "ctt_project_station")
  begin <- i[i$station_id==sensor,]$deploy_at
  filenameinfo <- sensorid[2]
  file_info <- unlist(strsplit(filenameinfo, "\\."))[1]
  filetype <- ifelse(is.na(as.integer(file_info)),file_info,"sensorgnome")
  if (is.na(filetype)) {
    filetype <- "none"
  } else if (filetype == "node" & !is.na(filetype)) {
    filetype <- "node_health"
  } else if (filetype == "data") {
      filetype <- "raw"
    }
  if (filetype %in% c("raw", "node_health", "gps")) {
    print("attempting import")
  contents <- tryCatch({
    if (file.size(e) > 0) {
      read_csv(e, col_names = TRUE)
    }}, error = function(err) {
      return(NULL)
    })
    if(!is.null(contents)) {
      delete.columns <- grep("(^X)", colnames(contents), perl=T)
      if (length(delete.columns) > 0) {
        contents <- rbind(contents,Correct_Colnames(contents))
      }
      if(filetype == "raw") {
        if (length(delete.columns) > 0) {
          if(ncol(contents) > 5) {
            names(contents) <- c("Time","RadioId","TagId","TagRSSI","NodeId","Validated")
          } else {names(contents) <- c("Time","RadioId","TagId","TagRSSI","NodeId")}
        }
      v <- ifelse(any(colnames(contents)=="Validated"), 2, 1)
      correct <- ifelse(v < 2, 5, 6)
      indx <- count.fields(e, sep=",")
      if(any(indx != correct)) {
        rowfix <- which(indx != correct) - 1
        getrow <- read.csv(e,as.is=TRUE, na.strings=c("NA", ""), skipNul = TRUE, skip=rowfix-1, nrow=1)
        getrow[,1]<- str_extract(getrow[,1], DatePattern) #handling assumes e.g. extra field and correct record starts in column 2
        if(any(grepl("T", getrow[,1]))) {
          vals <- as.POSIXct(getrow[,1],format="%Y-%m-%dT%H:%M:%OS",tz = "UTC", optional=TRUE)
        } else {
          vals <- unname(sapply(getrow[,1], function(x) as.POSIXct(x, format="%Y-%m-%d %H:%M:%OS", tz = "UTC", optional=TRUE)))
          vals1 <- sapply(vals, function(x) format(as.POSIXct(x, origin="1970-01-01", tz="UTC"),"%Y-%m-%d %H:%M:%OS"))
          vals <- as.POSIXct(vals1, tz="UTC")
        }
        getrow[,1] <- vals
        getrow[,3] <- as.character(getrow[,3])
        contents[rowfix,] <- getrow[1,]
      }
      } else if(filetype=="gps") {
        if(length(delete.columns) > 0) {
          if(ncol(contents) > 8) {
            names(contents) <- c("recorded.at","gps.at","latitude","longitude","altitude","quality","mean.lat","mean.lng","n.fixes")
          } else {names(contents) <- c("recorded.at","gps.at","latitude","longitude","altitude","quality")}
        }
      } else if(filetype == "node_health") {
        if (length(delete.columns) > 0) {
          if(ncol(contents) > 9) {
            names(contents) <- c("Time","RadioId","NodeId","NodeRssi","Battery","celsius","RecordedAt","firmware","SolarVolts","SolarCurrent","CumulativeSolarCurrent","latitude","longitude")
          } else {
            names(contents) <- c("Time","RadioId","NodeId","NodeRssi","Battery","celsius")
          }
        }
      }
      
      print("inserting contents")
      #if(fix=TRUE) {
      #z <- db_insert(contents, filetype, conn, sensor, y, begin, fix=TRUE)
      #} else {
        z <- db_insert(contents, filetype, conn, sensor, y, begin)
      #}
      }
  }
  if(!exists("z")) {z <- NULL}
}

patch <- function(d, outpath, myproject) {
myfiles <- list.files(file.path(outpath, myproject), recursive = TRUE)
files_loc <- sapply(strsplit(myfiles, "/"), tail, n=1)
failed2 <- lapply(myfiles, get_files_import, conn=d, outpath=outpath, myproject=myproject, fix=TRUE)
}
