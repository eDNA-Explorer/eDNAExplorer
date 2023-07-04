# plumber.R
library(plumber)
require(tidyr)
require(dplyr)
require(lubridate)
require(jsonlite)
require(jsonlite)
require(data.table)
require(DBI)
require(RPostgreSQL)
require(digest)
require(zoo)

#Establish database credentials.
readRenviron(".env")
Sys.setenv("AWS_ACCESS_KEY_ID" = Sys.getenv("AWS_ACCESS_KEY_ID"),
           "AWS_SECRET_ACCESS_KEY" = Sys.getenv("AWS_SECRET_ACCESS_KEY"))
db_host <- Sys.getenv("db_host")
db_port <- Sys.getenv("db_port")
db_name <- Sys.getenv("db_name")
db_user <- Sys.getenv("db_user")
db_pass <- Sys.getenv("db_pass")

#* Echo the parameter that was sent in
#* @param ProjectID:string
#* @param First_Date:string YYYY-MM-DD
#* @param Last_Date:string YYYY-MM-DD
#* @param Marker:string Target marker name
#* @param Num_Mismatch:numeric Maximum number of sequence mismatches allowed with Tronko-assign output
#* @param TaxonomicRank:string Taxonomic level to aggregate results to
#* @param CountThreshold:numeric Read count threshold for retaining samples
#* @param FilterThreshold:numeric Choose a threshold for filtering ASVs prior to analysis
#* @param SpeciesList:string Name of csv file containing selected species list.
#* @get /spacetime

spacetime <- function(ProjectID,First_Date,Last_Date,Marker,Num_Mismatch,TaxonomicRank,CountThreshold,FilterThreshold,SpeciesList){
  TaxonomicRanks <- c("superkingdom","kingdom","phylum","class","order","family","genus","species")
  CategoricalVariables <- c("grtgroup","biome_type","iucn_Cat","eco_name","hybas_id")
  ContinuousVariables <- c("bio01","bio12","ghm","elevation","ndvi","average_radiance")
  FieldVars <- c("fastqid","sample_date","latitude","longitude","spatial_uncertainty")
  First_Date <- lubridate::ymd(First_Date)
  Last_Date <- lubridate::ymd(Last_Date)
  Num_Mismatch <- as.numeric(Num_Mismatch)
  CountThreshold <- as.numeric(CountThreshold)
  FilterThreshold <- as.numeric(FilterThreshold)
  SelectedSpeciesList <- as.character(paste(SpeciesList,".csv",sep=""))
  
  #Establish sql connection
  Database_Driver <- dbDriver("PostgreSQL")
  sapply(dbListConnections(Database_Driver), dbDisconnect)
  
  #Read in metadata and filter it.
  con <- dbConnect(Database_Driver,host = db_host,port = db_port,dbname = db_name,user = db_user,password = db_pass)
  Metadata <- tbl(con,"TronkoMetadata")
  Keep_Vars <- c(CategoricalVariables,ContinuousVariables,FieldVars)[c(CategoricalVariables,ContinuousVariables,FieldVars) %in% dbListFields(con,"TronkoMetadata")]
  Metadata <- Metadata %>% filter(sample_date >= First_Date & sample_date <= Last_Date) %>%
    filter(ProjectID == ProjectID) %>% filter(!is.na(latitude) & !is.na(longitude)) %>% select(site,sample_id,sample_date,fastqid)
  Metadata <- as.data.frame(Metadata)
  sapply(dbListConnections(Database_Driver), dbDisconnect)
  
  #Read in Tronko output and filter it.
  con <- dbConnect(Database_Driver,host = db_host,port = db_port,dbname = db_name,user = db_user,password = db_pass)
  TronkoInput <- tbl(con,"TronkoOutput")
  TronkoInput <- TronkoInput %>% filter(ProjectID == ProjectID) %>% filter(Primer == Marker) %>% 
    filter(Mismatch <= Num_Mismatch & !is.na(Mismatch)) %>% filter(!is.na(!!sym(TaxonomicRank))) %>%
    group_by(SampleID) %>% filter(n() > CountThreshold) %>% 
    select(SampleID,TaxonomicRanks)
  TronkoDB <- as.data.frame(TronkoInput)
  if(SelectedSpeciesList != "None.csv"){TronkoDB <- TronkoDB[TronkoDB$SampleID %in% unique(na.omit(Metadata$fastqid)) & TronkoDB$species %in% SpeciesList_df$Species,]}
  if(SelectedSpeciesList == "None.csv"){TronkoDB <- TronkoDB[TronkoDB$SampleID %in% unique(na.omit(Metadata$fastqid)),]}
  sapply(dbListConnections(Database_Driver), dbDisconnect)
  
  #Read in Taxonomy output and filter it.
  con <- dbConnect(Database_Driver,host = db_host,port = db_port,dbname = db_name,user = db_user,password = db_pass)
  TaxonomyInput <- tbl(con,"Taxonomy")
  TaxaList <- na.omit(unique(TronkoDB[,TaxonomicRank]))
  TaxonomyInput <- TaxonomyInput %>% filter(rank == TaxonomicRank) %>% filter(Taxon %in% TaxaList) %>% select(Taxon,Common_Name,Image_URL)
  TaxonomyDB <-  as.data.frame(TaxonomyInput)
  colnames(TaxonomyDB) <- c(TaxonomicRank,"Common_Name","Image_URL")
  if(TaxonomicRank=="kingdom"){
    TaxonomyDB <- data.frame(kingdom=c("Fungi","Plantae","Animalia","Bacteria","Archaea","Protista","Monera","Chromista"),
                             Image_URL=c("https://images.phylopic.org/images/7ebbf05d-2084-4204-ad4c-2c0d6cbcdde1/raster/958x1536.png",
                                         "https://images.phylopic.org/images/573bc422-3b14-4ac7-9df0-27d7814c099d/raster/1052x1536.png",
                                         "https://images.phylopic.org/images/0313dc90-c1e2-467e-aacf-0f7508c92940/raster/681x1536.png",
                                         "https://images.phylopic.org/images/d8c9f603-8930-4973-9a37-e9d0bc913a6b/raster/1536x1128.png",
                                         "https://images.phylopic.org/images/7ccfe198-154b-4a2f-a7bf-60390cfe6135/raster/1177x1536.png",
                                         "https://images.phylopic.org/images/4641171f-e9a6-4696-bdda-e29bc4508538/raster/336x1536.png",
                                         "https://images.phylopic.org/images/018ee72f-fde6-4bc3-9b2e-087d060ee62d/raster/872x872.png",
                                         "https://images.phylopic.org/images/1fd55f6f-553c-4838-94b4-259c16f90c31/raster/1054x1536.png"))
  }
  sapply(dbListConnections(Database_Driver), dbDisconnect)
  
  #Merge Tronko output with sample metadata
  ProjectDB <- dplyr::left_join(TronkoDB,Metadata,by=c("SampleID"="fastqid"))
  #Get project duration
  Duration <- abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="days"))
  #Get day of year
  ProjectDB$day <- lubridate::yday(ProjectDB$sample_date)
  #Get week of year
  ProjectDB$week <- strftime(ProjectDB$sample_date,format="%V")
  #Get month of year
  ProjectDB$month <- lubridate::month(ProjectDB$sample_date)
  #Get quarter of year
  ProjectDB$quarter <- quarters(as.Date(ProjectDB$sample_date))
  #Get year
  ProjectDB$year <- lubridate::year(ProjectDB$sample_date)
  
  #Filter by relative abundance per taxon per sample.
  TronkoDB <- TronkoDB[!is.na(ProjectDB[,TaxonomicRank]),]
  TronkoDB <- TronkoDB %>% dplyr::group_by(SampleID,!!sym(TaxonomicRank)) %>% 
    dplyr::summarise(n=n()) %>% dplyr::mutate(freq=n/sum(n)) %>% 
    dplyr::ungroup() %>% dplyr::filter(freq > FilterThreshold) %>% select(-n,-freq)
  TronkoDB <- as.data.frame(TronkoDB)
  
  #Filter merged data.
  ProjectDB <- dplyr::inner_join(TronkoDB,ProjectDB,multiple="all")
  
  #Get start time of merged data.
  StartTime <- as.Date(paste(year(min(ProjectDB$sample_date)), 1, 1, sep = "-"))
  
  #Aggregate merged data by the appropriate time interval to find taxa presence by time.
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="days"))) <= 7){
    ProjectDB_byTime <- ProjectDB %>% dplyr::distinct(site,SampleID,day,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(day,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_byTime$date_range <- paste(StartTime+days(ProjectDB_byTime$day)-days(1),"to",StartTime+days(ProjectDB_byTime$day))
  }
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) > 1 &
     as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) <= 4){
    ProjectDB_byTime <- ProjectDB %>% dplyr::distinct(site,SampleID,week,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(week,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_byTime$date_range <- paste(StartTime+weeks(ProjectDB_byTime$week)-weeks(1),"to",StartTime+weeks(ProjectDB_byTime$week))
  }
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) > 4 &
     as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) <= 13){
    ProjectDB_byTime <- ProjectDB %>% dplyr::distinct(site,SampleID,month,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(month,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_byTime$date_range <- paste(StartTime+months(ProjectDB_byTime$month)-months(1),"to",StartTime+months(ProjectDB_byTime$month))
  }
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) > 13 &
     as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) <= 52){
    ProjectDB_byTime <- ProjectDB %>% dplyr::distinct(site,SampleID,quarter,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(quarter,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_byTime$date_range <- paste(as.Date(as.yearqtr(paste(ProjectDB_byTime$quarter,year(StartTime)), format = "Q%q %Y")),"to",as.Date(as.yearqtr(paste(ProjectDB_byTime$quarter,year(StartTime)), format = "Q%q %Y"))+months(3))
  }
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) > 52){
    ProjectDB_byTime <- ProjectDB %>% dplyr::distinct(site,SampleID,year,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(year,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_byTime$date_range <- paste(ProjectDB_byTime$year,"to",ProjectDB_byTime$year+1)
  }
  #Export taxa presence by time.
  ProjectDB_byTime <- as.data.frame(ProjectDB_byTime)
  #Merge in taxonomy data.
  ProjectDB_byTime <- dplyr::left_join(ProjectDB_byTime,TaxonomyDB)
  ProjectDB_byTime <- toJSON(ProjectDB_byTime)
  filename <- paste("PresenceByTime_Metabarcoding_Project",ProjectID,"FirstDate",First_Date,"LastDate",Last_Date,"Marker",Marker,"Rank",TaxonomicRank,"Mismatch",Num_Mismatch,"CountThreshold",CountThreshold,"AbundanceThreshold",format(FilterThreshold,scientific=F),"SpeciesList",gsub(".csv",".json",SelectedSpeciesList),sep="_")
  write(ProjectDB_byTime,filename)
  system(paste("aws s3 cp ",filename," s3://ednaexplorer/projects/",ProjectID,"/plots/",filename," --endpoint-url https://js2.jetstream-cloud.org:8001/",sep=""),intern=TRUE)
  system(paste("rm ",filename,sep=""))
  
  #Aggregate merged data by site to find taxa presence by site.
  ProjectDB_bySite <- ProjectDB %>% dplyr::distinct(site,SampleID,!!sym(TaxonomicRank),.keep_all=T) %>% 
    dplyr::group_by(site,!!sym(TaxonomicRank)) %>% 
    dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
  #Export taxa presence by site.
  ProjectDB_bySite <- as.data.frame(ProjectDB_bySite)
  #Merge in taxonomy data.
  ProjectDB_bySite <- dplyr::left_join(ProjectDB_bySite,TaxonomyDB)
  ProjectDB_bySite <- toJSON(ProjectDB_bySite)
  filename <- paste("PresenceBySite_Metabarcoding_Project",ProjectID,"FirstDate",First_Date,"LastDate",Last_Date,"Marker",Marker,"Rank",TaxonomicRank,"Mismatch",Num_Mismatch,"CountThreshold",CountThreshold,"AbundanceThreshold",format(FilterThreshold,scientific=F),"SpeciesList",gsub(".csv",".json",SelectedSpeciesList),sep="_")
  write(ProjectDB_bySite,filename)
  system(paste("aws s3 cp ",filename," s3://ednaexplorer/projects/",ProjectID,"/plots/",filename," --endpoint-url https://js2.jetstream-cloud.org:8001/",sep=""),intern=TRUE)
  system(paste("rm ",filename,sep=""))
  
  #Aggregate merged data by the appropriate time interval to find taxa presence by time.
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="days"))) <= 7){
    ProjectDB_bySiteTime <- ProjectDB %>% dplyr::distinct(site,SampleID,day,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(site,day,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_bySiteTime$date_range <- paste(StartTime+days(ProjectDB_bySiteTime$day)-days(1),"to",StartTime+days(ProjectDB_bySiteTime$day))
  }
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) > 1 &
     as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) <= 4){
    ProjectDB_bySiteTime <- ProjectDB %>% dplyr::distinct(site,SampleID,week,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(site,week,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_bySiteTime$date_range <- paste(StartTime+weeks(ProjectDB_bySiteTime$week)-weeks(1),"to",StartTime+weeks(ProjectDB_bySiteTime$week))
  }
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) > 4 &
     as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) <= 13){
    ProjectDB_bySiteTime <- ProjectDB %>% dplyr::distinct(site,SampleID,month,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(site,month,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_bySiteTime$date_range <- paste(StartTime+months(ProjectDB_bySiteTime$month)-months(1),"to",StartTime+months(ProjectDB_bySiteTime$month))
  }
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) > 13 &
     as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) <= 52){
    ProjectDB_bySiteTime <- ProjectDB %>% dplyr::distinct(site,SampleID,quarter,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(site,quarter,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_bySiteTime$date_range <- paste(as.Date(as.yearqtr(paste(ProjectDB_bySiteTime$quarter,year(StartTime)), format = "Q%q %Y")),"to",as.Date(as.yearqtr(paste(ProjectDB_bySiteTime$quarter,year(StartTime)), format = "Q%q %Y"))+months(3))
  }
  if(as.numeric(abs(difftime(range(ProjectDB$sample_date)[1],range(ProjectDB$sample_date)[2],units="weeks"))) > 52){
    ProjectDB_bySiteTime <- ProjectDB %>% dplyr::distinct(site,SampleID,year,!!sym(TaxonomicRank),.keep_all=T) %>% 
      dplyr::group_by(site,year,!!sym(TaxonomicRank)) %>% 
      dplyr::summarise(n=n_distinct(SampleID)) %>% dplyr::mutate(freq=n/max(n)) %>% select(-n)
    ProjectDB_bySiteTime$date_range <- paste(ProjectDB_bySiteTime$year,"to",ProjectDB_bySiteTime$year+1)
  }
  #Export taxa presence by time.
  ProjectDB_bySiteTime <- as.data.frame(ProjectDB_bySiteTime)
  #Merge in taxonomy data.
  ProjectDB_bySiteTime <- dplyr::left_join(ProjectDB_bySiteTime,TaxonomyDB)
  ProjectDB_bySiteTime <- toJSON(ProjectDB_bySiteTime)
  filename <- paste("PresenceBySiteAndTime_Metabarcoding_Project",ProjectID,"FirstDate",First_Date,"LastDate",Last_Date,"Marker",Marker,"Rank",TaxonomicRank,"Mismatch",Num_Mismatch,"CountThreshold",CountThreshold,"AbundanceThreshold",format(FilterThreshold,scientific=F),"SpeciesList",gsub(".csv",".json",SelectedSpeciesList),sep="_")
  write(ProjectDB_bySiteTime,filename)
  system(paste("aws s3 cp ",filename," s3://ednaexplorer/projects/",ProjectID,"/plots/",filename," --endpoint-url https://js2.jetstream-cloud.org:8001/",sep=""),intern=TRUE)
  system(paste("rm ",filename,sep=""))

  #Export filtered taxonomy table.
  TronkoTable <- ProjectDB[,c("sample_id",TaxonomicRanks)]
  TronkoTable$sum.taxonomy <- apply(ProjectDB[ ,TaxonomicRanks] , 1 , paste , collapse = ";" )
  TronkoTable <- as.data.frame(table(TronkoTable[,c("sample_id","sum.taxonomy")]))
  TronkoTable <- as.data.frame(pivot_wider(TronkoTable, names_from = sample_id, values_from = Freq))
  filename <- paste("FilteredTaxonomy_Metabarcoding_Project",ProjectID,"FirstDate",First_Date,"LastDate",Last_Date,"Marker",Marker,"Mismatch",Num_Mismatch,"CountThreshold",CountThreshold,"AbundanceThreshold",format(FilterThreshold,scientific=F),"SpeciesList",SelectedSpeciesList,sep="_")
  write(TronkoTable,filename)
  system(paste("aws s3 cp ",filename," s3://ednaexplorer/projects/",ProjectID,"/tables/",filename," --endpoint-url https://js2.jetstream-cloud.org:8001/",sep=""),intern=TRUE)
  system(paste("rm ",filename,sep=""))
}