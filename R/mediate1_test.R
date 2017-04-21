# Mediation tests
#
#' Develop mediation models from driver, target and mediator
#'
#' @param driver vector or matrix with driver values
#' @param target vector or 1-column matrix with target values
#' @param mediator matrix with mediator values by column
#' @param fitFunction function to fit models with driver, target and mediator
#' @param kinship optional kinship matrix among individuals
#' @param cov_tar optional covariates for target
#' @param cov_med optional covariates for mediator
#' @param annotation Table with annotation, with \code{id} 
#' agreeing with column names of \code{mediator}.
#' @param test Type of CMST test.
#' @param pos Position of driver.
#' @param lod_threshold LOD threshold to include mediator.
#' @param ... additional parameters
#'
#' @importFrom purrr map transpose
#' @importFrom stringr str_replace
#' @importFrom qtl2scan fit1 get_common_ids
#' @importFrom dplyr arrange bind_rows filter left_join rename
#' @importFrom ggplot2 aes autoplot facet_grid geom_hline geom_point geom_vline ggplot ggtitle
#' @importFrom RColorBrewer brewer.pal
#'
#' @export
#'
mediate1_test <- function(driver, target, mediator, fitFunction,
                          kinship=NULL, cov_tar=NULL, cov_med=NULL,
                          annotation, test = c("wilc","binom","joint","norm"),
                          pos = NULL,
                          lod_threshold = 5.5,
                          ...) {

  test <- match.arg(test)
  testfn <- switch(test,
                   wilc = CausalMST::wilcIUCMST,
                   binom = CausalMST::binomIUCMST,
                   joint = CausalMST::normJointIUCMST,
                   norm = CausalMST::normIUCMST)
  tmpfn <- function(x, models) {
    models <- subset(models, x)
    dplyr::filter(
      testfn(models),
      pv == min(pv))
  }
  
  pos_t <- pos

  scan_max <- fitFunction(driver, target, kinship, cov_tar)
  lod_t <- scan_max$lod
  
  commons <- common_data(driver, target, mediator,
                         kinship, cov_tar, cov_med)
  driver <- commons$driver
  target <- commons$target
  mediator <- commons$mediator
  kinship <- commons$kinship
  cov_tar <- commons$cov_tar
  cov_med <- commons$cov_med
  
  cmst_fit <- function(x, driver) {
    # Force x (= mediator column) to be matrix.
    x <- as.matrix(x)
    rownames(x) <- rownames(driver)
    colnames(x) <- "M"
    # Fit mediation models.
    models_par <- mediationModels(driver, target, x, 
                                  qtl2scan::fit1,
                                  kinship, cov_tar, cov_med,
                                  common = TRUE)
    # CMST on quatrads
    out <- dplyr::filter(
      testfn(subset(models_par$models, 1:4)),
      pv == min(pv))
    # Mediation LOD
    med_lod <- sum(models_par$comps$LR[c("t.d_t", "mediation")]) / log(10)
    # Mediator LOD
    medor_lod <- models_par$comp$LR["m.d_m"] / log(10)
    out$mediation <- med_lod
    out$mediator <- medor_lod
    
    out
  }

  best <- purrr::map(as.data.frame(mediator), 
                     cmst_fit, 
                     driver)
  best <- dplyr::rename(
    dplyr::filter(
      dplyr::bind_rows(best, .id = "id"),
      mediator >= lod_threshold),
    triad = ref)
  
  relabel <- c("causal", "reactive", "independent", "correlated")
  names(relabel) <- c("m.d_t.m", "t.d_m.t", "t.d_m.d", "t.md_m.d")
  best$triad <- factor(relabel[best$triad], relabel)
  best$alt <- factor(relabel[best$alt], relabel)
  
  result <- dplyr::arrange(
    dplyr::left_join(best, annotation, by = "id"),
    pv)

  attr(result, "pos") <- pos_t
  attr(result, "lod") <- lod_t
  attr(result, "target") <- colnames(target)
  
  class(result) <- c("mediate1_test", class(result))
  result
}

#' @export
plot.mediate1_test <- function(x, ...)
  ggplot2::autoplot(x, ...)
#' @export
autoplot.mediate1_test <- function(x, ...)
  plot_mediate1_test(x, ...)
#' @export
plot_mediate1_test <- function(x, type = c("pos_lod","pos_pv","pv_lod"),
                               main = attr(x, "target"),
                               threshold = 0.1, ...) {
  type <- match.arg(type)
  
  pos_t <- attr(x, "pos")
  lod_t <- attr(x, "lod")
  
  pg <- grep("pheno_group", names(x))
  if(length(pg))
    names(x)[pg] <- "biotype"
  
  relabel <- c(levels(x$triad), paste0("n.s. (p>", round(threshold, 2), ")"))
  tmp <- as.character(x$triad)
  tmp[x$pv > threshold] <- relabel[5]
  x$triad <- factor(tmp, levels = relabel)
  x <- dplyr::arrange(x, dplyr::desc(triad))
  
  # Colors
  cols <- c(RColorBrewer::brewer.pal(4, "Dark2"), "#CCCCCC")
  names(cols) <- relabel

  switch(type,
         pos_pv = {
           p <- ggplot2::ggplot(dplyr::filter(x, x$pv <= threshold), 
               ggplot2::aes(x=pos, y=-log10(pv), col=biotype, 
                            symbol=symbol, mediation=mediation)) +
             ggplot2::geom_point(size = 3) +
             ggplot2::facet_grid(~triad) +
             xlab("Position (Mbp)") +
             ylab("-log10 of p-value")
           if(!is.null(pos_t))
             p <- p +
               ggplot2::geom_vline(xintercept = pos_t, col = "darkgrey")
         },
         pv_lod = {
           p <- ggplot2::ggplot(dplyr::filter(x, x$pv <= threshold), 
             ggplot2::aes(y=mediation, x=-log10(pv), col=biotype, 
                          symbol=symbol, position=pos)) +
             ggplot2::geom_point(size = 3) +
             ggplot2::facet_grid(~triad) +
             ggplot2::geom_hline(yintercept = lod_t, col = "darkgrey") +
             xlab("-log10 of p-value") +
             ylab("Mediation LOD")
         },
         pos_lod = {
           p <- ggplot2::ggplot(x, 
               ggplot2::aes(y=mediation, x=pos, col=triad, 
                            symbol=symbol, pvalue=pv, biotype=biotype)) +
             ggplot2::geom_point(size = 3) +
             ggplot2::geom_hline(yintercept = lod_t, col = "darkgrey") +
             xlab("Position (Mbp)") +
             ylab("Mediation LOD") +
             scale_color_manual(values = cols)
           if(!is.null(pos_t))
             p <- p +
               ggplot2::geom_vline(xintercept = pos_t, col = "darkgrey")
         })
  p + ggplot2::ggtitle(main)
}