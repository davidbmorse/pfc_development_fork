#Seurat sctransform attempt


library(BiocManager)
library(scater)
library(scran)
library(scuttle)
library(reticulate)
library(Seurat)
library(uwot)
library(stringr)


rawref= readRDS('snRNAseq/processed_data/2020-12-18_RAW_whole-tissue_post-restaged-GABA-clustering.RDS')
rownames(rawref) = rowData(rawref)$gene_ids
reference = readRDS('snRNAseq/processed_data/2020-12-18_whole-tissue_post-restaged-GABA-clustering.RDS') 

#prepare reference - no downsampling

seuraw = CreateSeuratObject(counts = counts(rawref), 
    meta.data = as.data.frame(colData(reference)))
VariableFeatures(seuraw) = subset(rowData(reference)$gene_ids, 
    rowData(reference)$highly_variable == TRUE)
seuraw[['PCA']] = CreateDimReducObject(embeddings = 
    reducedDim(reference, 'PCA')[,1:365], key = 'PCA_')
seuraw[['UMAP']] = CreateDimReducObject(embeddings = 
    reducedDim(reference, 'UMAP'),key = 'UMAP_')
seuraw[['PCA_est']] = CreateDimReducObject(embeddings = 
    reducedDim(reference, 'PCA_est')[,1:365], key = 'PCA_est', 
    loadings = attributes(reducedDim(reference, 'PCA_est'))$rotation)
attributes(seuraw[['PCA_est']]@feature.loadings)$dimnames[[1]] = 
    VariableFeatures(seuraw)
seuraw = SCTransform(seuraw, verbose = TRUE, 
    do.correct.umi = FALSE, residual.features=VariableFeatures(seuraw))


query = readRDS('snRNAseq/processed_data/transfer_learning/datasets/velmeshev_dataset.RDS') 
# this can be downloaded by https://www.science.org/doi/abs/10.1126/science.aav8130

ribogeneset = read.csv('annotation/ribo_geneset.txt', header = FALSE)$V1
ribout = subset(rowData(query)$ID, rowData(query)$Symbol %in% ribogeneset)

query = query[!( rownames(query) %in% ribout),]
query = query[rowData(query)$Symbol != 'MALAT1',]
query =query[-which(str_detect(rowData(query)$Symbol, '^MT-')),]
query = query[rowSums(counts(query)>0)>=5,]

seuq = CreateSeuratObject(counts = counts(query), 
    meta.data = as.data.frame(colData(query)))
VariableFeatures(seuq) = subset(rownames(seuq), 
    rownames(seuq) %in% VariableFeatures(seuraw))


qanchors = FindTransferAnchors(reference = seuraw, query = seuq, 
    normalization.method='SCT', reduction = 'pcaproject', 
    reference.reduction = "PCA_est", npcs = 365, dims = 1:365, l2.norm=FALSE)


qproj = qanchors@object.list[[1]]@reductions$pcaproject@cell.embeddings[154749:207304,]
refproj = qanchors@object.list[[1]]@reductions$pcaproject@cell.embeddings[1:154748,]
initembedding = reducedDim(reference, "UMAP")

reference_umap = umap(refproj, n_neighbors = 25, ret_model = TRUE, 
                      init = initembedding, a = 0.58303, b = 1.334167, spread = 1, 
                      min_dist = 0.5, verbose = TRUE, n_epochs = 0)
qumap = umap_transform(qproj, reference_umap, n_epochs = 50)

qumap = as.data.frame(qumap)
qumap$dataset = character(nrow(qumap))
qumap$dataset[1:nrow(qumap)] = 'velmeshev'

qumap$pred = knn.reg(train = refmap[,1:2], 
                     test = qumap[,1:2], y = reference$arcsin_ages, k = 10)$pred
qumap$cluster = knn(train = refmap[,1:2], 
                    test = qumap[,1:2], cl = reference$cluster, k = 10)
qumap$age = query$age
qumap$diff = abs(qumap$pred - qumap$age)

qumap$sample = query$sample
qumap$sample = fct_reorder(qumap$sample, qumap$age)
qumap = subset(qumap, !(sample %in% 
                          c('5893_PFC', '5538_PFC_Nova', '5879_PFC_Nova','5936_PFC_Nova', 
                            '5408_PFC_Nova', '5144_PFC', '5278_PFC', '5403_PFC', 
                            '5419_PFC', '5945_PFC')))
smolquery = query[, !(query$sample %in% c('5893_PFC', '5538_PFC_Nova', 
                                          '5879_PFC_Nova','5936_PFC_Nova', '5408_PFC_Nova', '5144_PFC', 
                                          '5278_PFC', '5403_PFC', '5419_PFC', '5945_PFC'))]


myknn = function(ref_embed, ref_class, test_embed, test_class, k){
  
  output = list()
  kest = knn(train = ref_embed, test = test_embed, 
             cl = as.factor(ref_class), prob=TRUE, k =k)
  result = character(nrow(test_embed))
  
  for(i in 1:nrow(test_embed)){
    if(kest[i] == as.factor(test_class)[i]) {     
      result[i] = "correct"
    }
    else {
      result[i] = "incorrect"
    }
  }
  
  output$result = result
  correct = subset(test_class, result == "correct")
  incorrect = subset(test_class, result == "incorrect")
  output$correct = correct
  output$incorrect = incorrect
  output$accuracy = length(correct)/length(result)
  output$corprop = summary(correct)/length(correct)
  output$est = kest
  output$percents = summary(correct)/summary(test_class)
  
  return(output)
  
}


out = myknn(ref_embed = refmap[,1:2], test_embed = qumap[,1:2], 
            test_class = smolquery$cluster, ref_class = reference$cluster, k =10)
qumap$result = out$result
qumap$truecluster = smolquery$cluster

astro = subset(qumap, cluster == 'Astro' & result == 'correct')
l23 = subset(qumap, cluster == 'L2/3_CUX2' & result == 'correct')

plotastro = ggplot(astro, aes(x = pred, y = sample, fill = ..x..))+ geom_density_ridges_gradient(bandwidth = 0.25) + 
  xlim(-1,5.5) + theme_classic() +
  ggtitle('Predicted astrocyte ages by sample') + xlab('predicted age') +
  scale_x_continuous(breaks = c(as.numeric(levels(as.factor(reference$arcsin_ages)))[-c(2,3, 4,6,7,8,10,11,12,14,15,16,18, 19, 20,21,23)]),
                     label = c('ga22', 
                               '34d', 
                               '301d', 
                               '3yr', '10yr',
                               '20yr', '40yr'))+
  scale_fill_viridis_c()



plotl23 = ggplot(l23, aes(x = pred, y = sample, fill = ..x..)) + geom_density_ridges_gradient(bandwidth = 0.25) + 
  xlim(-1,5.5) + theme_classic() +
  ggtitle('Predicted L2/3 ages by sample') + xlab('predicted age') +
  scale_x_continuous(breaks = c(as.numeric(levels(as.factor(reference$arcsin_ages)))[-c(2,3, 4,6,7,8,10,11,12,14,15,16,18, 19, 20,21,23)]),
                     label = c('ga22', 
                               '34d', 
                               '301d', 
                               '3yr', '10yr',
                               '20yr', '40yr'))+
  scale_fill_viridis_c()


ggsave(plotastro, 'supp_figures/velmeshev_seurat_astro_age_prediction.png')
ggsave(plotl23, 'supp_figures/velmeshev_seurat_l23_age_prediction.png')

saveRDS(qproj, "snRNAseq/processed_data/transfer_learning/seurat_velmeshev_projected.RDS")
saveRDS(qumap, "snRNAseq/processed_data/transfer_learning/seurat_velmeshev_umap.RDS")

#process can be repeated to include additional datasets

