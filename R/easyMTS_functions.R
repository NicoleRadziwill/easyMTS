library(MASS)            # for ginv function
library(qualityTools)    # for taguchiDesign function
library(tidyverse)       # for data handling, pipes, and plotting
library(highcharter)     # for an alternative to ggplot
library(cowplot)         # for formatting plots in diffMTS

computeMDs <- function(good, bad) {
  # This function computes Mahalanobis Distances (MDs) for "good" and "bad" groups.
  # Takes two data frames as inputs and produces a list of MD.good and MD.bad -- the object
  # returned by this function can be ingested by plotMDs
  if (!is.data.frame(good) || !is.data.frame(bad)) {
    stop("At least one input is not a data frame")
  } else {
    # Compute means and sd's for "good" group
    xbars <- colMeans(good)
    sds <- apply(good, 2, sd)
    pinv <- 1/ncol(good)
    Rinv <- ginv(cor(good))

    # Compute MDs for bad group by using means and sds of "good" group as a baseline
    z0s <- apply(bad, 1, function(x) (x-xbars)/sds)
    MD.bad <- pinv * diag( (t(z0s) %*% Rinv %*% z0s) )

    # Compute MDs for good group
    z0s.good <- apply(good, 1, function(x) (x-xbars)/sds)
    MD.good <- pinv * diag( (t(z0s.good) %*% Rinv %*% z0s.good) )

    return(list(MD.bad=MD.bad, MD.good=MD.good))
  }
}

plotMDs <- function(computeMDs_obj, type="bars") {
  bar.df <- data.frame(
    index=seq(1, length(computeMDs_obj$MD.good) + length(computeMDs_obj$MD.bad), 1),
    md=c(computeMDs_obj$MD.good, computeMDs_obj$MD.bad),
    group=c(rep("normal", length(computeMDs_obj$MD.good)), rep("abnormal",length(computeMDs_obj$MD.bad) ))
  )
  if (type == "bars") {
    bar.df %>% ggplot() + geom_bar(aes(x=index, y=md), stat="identity") +
      ggtitle("Comparison of MDs between Normal and Abnormal Groups")
  } else if (type == "hc_scatter") {
    hchart(bar.df, "scatter", hcaes(x = index, y = md, group = group)) %>% hc_colors(c("red","blue"))
  } else if (type == "hc_column") {
    highchart() %>% hc_chart(type = "column") %>% hc_add_series(data = bar.df$md, name = "MD")
  }
}

generateTDO <- function(good) {
  # This function can take as input either the good or bad data frame, since both have same ncol.
  # Alternatively, you can just give it the number of IVs directly and it will still work.
  if (!is.data.frame(good)) {
    ivs <- good
  } else {
    ivs <- ncol(good)
  }
  if (ivs %in% c(2:3)) {
    tdo <- taguchiDesign("L4_2")@design[,1:ivs] %>% replace(.=="2",0)
  } else if (ivs %in% c(4:7)) {
    tdo <- taguchiDesign("L8_2")@design[,1:ivs] %>% replace(.=="2",0)
  } else if (ivs %in% c(8:11)) {
    tdo <- taguchiDesign("L12_2")@design[,1:ivs] %>% replace(.=="2",0)
  } else if (ivs %in% c(12:15)) {
    tdo <- taguchiDesign("L16_2")@design[,1:ivs] %>% replace(.=="2",0)
  } else if (ivs==1 || ivs > 15) {
    stop(paste0("Number of independent variables ",ivs," is not supported"))
  }
  return(tdo=tdo)
}

# Functions to compute Taguchi Signal to Noise (SN)
ltb <- function(x) {
  -10*log10( (1/(length(x))) * sum(1/(x^2) ))
}   # Larger-the-better

stb <- function(x) {
  -10*log10( (1/(length(x))) * sum(  (x^2) ))
}   # Smaller-the-better

dyn.sn <- function(x, y) {
  stb(x) - ltb(y)
}

runTaguchi <- function(good, bad, tdo) {
  # This function takes the data frames of good and bad observations + the Taguchi Orthogonal Array design (tdo)
  # created by the generateTDO function and runs all signal-to-noise experiments on the MDs.
  # It returns a matrix of experimental results, with one row per Taguchi experiment, and one column
  # per predictor/independent variable.

  all.results <- NULL

  for (i in 1:(nrow(tdo)) ) {
    exp.bad <- 0; exp.good <- 0

    exp.bad  <- as.data.frame(mapply(`*`, bad, tdo[i,]))
    exp.bad  <- exp.bad[, colSums(exp.bad != 0) > 0]        # drop all columns that contain all zeroes
    exp.good <- as.data.frame(mapply(`*`, good, tdo[i,]))
    exp.good <- exp.good[, colSums(exp.good != 0) > 0]      # drop all columns that contain all zeroes

    if (is.vector(exp.good)) { # this indicates there is only ONE active column in the Taguchi array
      xbars <- mean(exp.good)
      sds <- sd(exp.good)
      # pinv will be 1/1 because only one predictor
      Rinv <- ginv(cor(as.matrix(exp.good)))
      z0s <- (exp.bad-xbars)/sds
      as.vector(t(z0s)*z0s) -> results
      all.results <- rbind(all.results, results)

    } else if (is.data.frame(exp.good)) {                  # there are MULTIPLE active columns to process in the Taguchi array
      xbars <- colMeans(exp.good)
      sds <- apply(exp.good, 2, sd)
      pinv <- 1/ncol(exp.good)
      Rinv <- ginv(cor(exp.good))
      z0s <- apply(exp.bad, 1, function(x) (x-xbars)/sds)  # scale bad group based on xbar/sd of good group
      as.vector(pinv * diag( (t(z0s) %*% Rinv %*% z0s) )) -> results
      all.results <- rbind(all.results, results)

    }
  }
  rownames(all.results) <- NULL
  return(all.results)
}

addSN <- function(taguchiResults, method="ltb") {
  # This function takes the results from runTaguchi, and appends a SN column to it
  # based on whether you want larger-the-better, smaller-the-better, or dynamic (stb-ltb) SN.
  if (is.data.frame(taguchiResults)) {
    if (method == "stb") {
      taguchiResults %>% mutate(sn=apply(taguchiResults,1,stb)) -> sn.df
    } else if (method == "dyn") {
      taguchiResults %>% mutate(sn=apply(taguchiResults,1,dyn)) -> sn.df
    } else {
      taguchiResults %>% mutate(sn=apply(taguchiResults,1,ltb)) -> sn.df
    }
  } else {
    stop("The addSN function requires a data frame containing Taguchi experiment results")
  }
  return(sn.df)
}

calcGains <- function(tdo, df) {
  # This function calculates average SN for each predictor/independent variable when it was used (Level 1)
  # and also when it was not used (Level 2) in each of the Taguchi experiments. The difference between
  # these two averages as you move from Level 1 to Level 2 is called the gain.
  # For example, if the first predictor/independent variable was used in 3 of 8 Taguchi experiments, the
  # Level 1 SN for X1 would be the average of these three SNs, while the Level 2 SN would be the average of
  # SNs for the 5 experiments where X1 was not used.

  level1 <- colMeans(apply(tdo, 2, function(x) x*df$sn))
  level2s <- as.data.frame(matrix(as.numeric(!tdo), nrow=nrow(tdo)))
  level2 <- colMeans(apply(level2s, 2, function(x) x*df$sn))

  gains.df <- as.data.frame(cbind(level1, level2, gain=level1-level2), rownames=colnames(x))
  gains.df$var <- colnames(good)

  return(gains.df)
}

plotGains <- function(tdo, gains.df, type="bars") {
  # This function plots the output of calcGains. Negative gain indicates that the predictor does not
  # enhance the discriminatory power of the MTS. On the main effects plot, downward sloping lines
  # indicate predictors that do not enhance the discriminatory power.

  if (type == "bars") {
    gains.df %>% ggplot() + geom_bar(aes(x=var, y=gain), stat="identity") +
      ggtitle("Gain in SN Ratios for Each Variable")
  } else if (type == "maineffects") {
    gains.df %>% select(-gain) %>%
      pivot_longer(cols=starts_with("level"), names_to="level", values_to="value") %>%
      ggplot(aes(level, value, group=var)) + geom_line(lwd=2) +
      facet_wrap(~var,ncol=ncol(good))
  } else if (type == "hc_scatter") {
    hchart(gains.df, "scatter", hcaes(x = var, y = gain, group = sign(gain))) %>%
      hc_colors(c("red","blue")) %>% hc_add_series(showInLegend = FALSE)
  } else if (type == "hc_column") {
    highchart() %>% hc_chart(type = "column") %>% hc_add_series(data = gains.df$gain, name = "gain")
  }
}


recommend <- function(gains.df, type="print") {
  # This function tells you what variables to use for discriminating between "good" and "bad" groups.
  # If argument "pretty" is used, it generates a flextable containing the recommended variables.

  if (type == "print") {
    gains.df %>% filter(gain > 0) %>% select(var) %>% as.list()

  } else if (type == "pretty") {
    gains.df %>% filter(gain > 0) %>% select(var) %>% regulartable() %>% autofit()
  }
}

diffMTS <- function(mts1, mts2) {
  # This function takes two objects from compareMDs: your INITIAL set of MDs from good and bad groups with all potential
  # predictor variables included, and your FINAL set of MDs after feature selection.

  compare <- data.frame(index = seq(1, length(unlist(mts1)), 1),
                        md.old = c(mts1$MD.good, mts1$MD.bad),
                        md.new = c(mts2$MD.good, mts2$MD.bad))

  compare %>% mutate(diff = md.new - md.old) -> compare

  g1 <- compare %>% ggplot() + geom_line(aes(x = index, y = md.old), color="blue") +
    geom_line(aes(x = index, y = md.new), color="red", lwd=2)+
    ggtitle("Discrimination Power After Feature Selection (Red)")

  g2 <- compare %>% ggplot() + geom_histogram(aes(x=diff)) + geom_vline(xintercept=2, col="red") +
    ggtitle("Differences in Mahalanobis Distance (MD) after Feature Selection")

  cowplot::plot_grid(g1, g2)
}
